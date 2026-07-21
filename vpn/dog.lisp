;;; dog.lisp
;;;
;;; One watcher thread, two jobs, checked on every tick so they can never
;;; race each other:
;;;
;;;   1. Proxy liveness — server unreachable N times in a row -> (stop-full),
;;;      fall back to a direct connection so you're never stuck without
;;;      internet. Reachable again M times in a row (while in fallback) ->
;;;      (start-full) again, tunnel restored automatically.
;;;
;;;   2. Network changes — Wi-Fi toggled, machine slept/woke, or reconnected
;;;      to a different network. Detected via polling *watched-interface*'s
;;;      status/IP, plus a wall-clock gap check for the sleep case (some
;;;      Macs keep reporting Wi-Fi as "active" straight through a lid-close,
;;;      so the status/IP check alone won't catch every wake). If the
;;;      tunnel is supposed to be up when this happens, the routes captured
;;;      before the change are stale (the gateway itself is owned by
;;;      lisp-vpn-priv, not tracked here — see tun-ctl.lisp), so we force a
;;;      fresh (stop-full) + (start-full) rather than waiting for the
;;;      liveness check to notice indirectly.
;;;
;;; These two used to be separate watchers in separate threads (dog.lisp +
;;; netwatch.lisp) coordinated by a shared mutex. Merged into one thread
;;; instead: a single sequential loop makes the "never run stop-full/
;;; start-full concurrently" guarantee free, by construction, no lock
;;; needed.
;;;
;;; This is the only file you load. It pulls in singbox-ctl.lisp and
;;; tun-ctl.lisp itself, resolved relative to its own location
;;; (*load-truename*), so it doesn't matter what the current directory is
;;; when you load it:
;;;
;;;   (load "dog.lisp")
;;;   (connect)

(let ((here (or *load-truename* *load-pathname*
                (error "dog.lisp must be loaded via (load ...), not evaluated form by form — ~
                        *load-truename* is how it finds singbox-ctl.lisp and tun-ctl.lisp next to it"))))
  (load (merge-pathnames "singbox-ctl.lisp" here))
  (load (merge-pathnames "tun-ctl.lisp" here)))

;;; --- config: proxy liveness ---

(defparameter *proxy-server-port* 8080
  "Port of the currently active proxy server. Update this alongside
   *proxy-server-ip* whenever you switch configs.")

(defparameter *poll-interval* 5
  "Seconds between checks — both proxy liveness and network state are
   checked on the same tick. Kept fairly relaxed on purpose: false
   verdicts cost more (needless reconfigures) than a slightly slower
   reaction to a real change, since recovery is automatic anyway.")

(defparameter *fail-threshold* 8
  "Consecutive failed proxy checks before declaring the server dead and
   falling back to direct. At *poll-interval*=5 this is ~40s.")

(defparameter *revive-threshold* 8
  "Consecutive successful proxy checks (while in fallback) before
   restoring the tunnel. Same ~40s window as *fail-threshold* — a false
   positive either way just costs one extra reconfigure cycle, the next
   tick catches and corrects it.")

;;; --- config: network-change detection ---

(defparameter *watched-interface* "en0"
  "Physical interface to watch for status/IP changes — Wi-Fi on most Macs.
   Check `networksetup -listallhardwareports` if en0 isn't right on yours.")

(defparameter *sleep-gap-threshold* 20
  "If more wall-clock time passes between two ticks than this, conclude
   the machine was asleep, regardless of what ifconfig reports right now.
   Must be comfortably larger than *poll-interval*.")

(defparameter *settle-delay* 5
  "Seconds to wait after detecting a network change, before reconfiguring
   — gives DHCP/DNS a moment to actually come back up. Reconfiguring
   against a half-up interface just reproduces the original 'no internet'
   failure mode.")

;;; --- state ---

(defparameter *thread* nil)
(defparameter *running* nil)
(defparameter *regime* :tunnel) ; :tunnel | :direct

;;; --- proxy liveness check ---

(defun tcp-alive-p (host port &key (timeout 3))
  "TCP connect check via nc — true if something accepts a connection
   on host:port within timeout seconds. Deliberately not an ICMP
   ping: many hosts firewall ICMP while the actual proxy port is
   fine, and ping-ok says nothing about whether the proxy service
   itself is still alive."
  (let ((proc (sb-ext:run-program "/usr/bin/nc"
                                  (list "-z" "-w" (princ-to-string timeout)
                                        host (princ-to-string port))
                                  :output nil :error nil :wait t)))
    (zerop (sb-ext:process-exit-code proc))))

(defun server-alive-p ()
  (tcp-alive-p *proxy-server-ip* *proxy-server-port*))

;;; --- interface introspection (read-only, unprivileged) ---

(defun if-status ()
  "Returns (values status ip) for *watched-interface*, e.g. (\"active\"
   \"192.168.1.23\") or (\"inactive\" nil). Never errors — a missing or
   unreadable interface just reads as inactive/nil, which is itself a
   valid 'something about the network changed' signal."
  (let ((output (ignore-errors
                 (with-output-to-string (s)
                   (sb-ext:run-program "/sbin/ifconfig" (list *watched-interface*)
                                       :output s :error nil :wait t)))))
    (unless output
      (return-from if-status (values "inactive" nil)))
    (let* ((lines (uiop:split-string output :separator '(#\Newline)))
           (status-line (find-if (lambda (l) (search "status:" l)) lines))
           (inet-line (find-if (lambda (l) (search "inet " l)) lines))
           (status (if status-line
                       (string-trim '(#\Space #\Tab)
                                    (second (uiop:split-string status-line :separator '(#\:))))
                       "unknown"))
           (ip (when inet-line
                 (second (uiop:split-string (string-trim '(#\Space #\Tab) inet-line)
                                            :separator '(#\Space))))))
      (values status ip))))

(defun detect-network-change (last-status last-ip last-tick now cur-status cur-ip)
  "Returns a reason string if something changed since the last tick, else nil."
  (cond
    ((> (- now last-tick) *sleep-gap-threshold*)
     (format nil "~as gap since last check, likely sleep/wake" (- now last-tick)))
    ((not (string= cur-status last-status))
     (format nil "~a status ~a -> ~a" *watched-interface* last-status cur-status))
    ((not (equal cur-ip last-ip))
     (format nil "~a IP changed ~a -> ~a" *watched-interface* last-ip cur-ip))))

;;; --- reconfigure ---

(defun full-reconfigure (reason)
  (format t "~&[dog] network change (~a), waiting ~as to settle~%" reason *settle-delay*)
  (sleep *settle-delay*)
  ;; If we reconnected to a different network, teardown-routes may fail to
  ;; restore the old gateway (unreachable from here now) — lisp-vpn-priv
  ;; still clears its captured-gateway state either way (see
  ;; lisp-vpn-priv.c), so the start-full below can capture a fresh,
  ;; correct gateway for whatever network we're actually on now.
  (ignore-errors (stop-full))
  (sleep 1)
  (ignore-errors (start-full))
  (format t "~&[dog] reconfigure done~%"))

;;; --- main loop ---

(defun cycle ()
  (let ((fail-count 0) (ok-count 0))
    (multiple-value-bind (if-status0 if-ip0) (if-status)
      (let ((last-if-status if-status0)
            (last-if-ip if-ip0)
            (last-tick (get-universal-time)))
        (loop while *running* do
              (sleep *poll-interval*)
              (let ((now (get-universal-time)))
                (multiple-value-bind (cur-if-status cur-if-ip) (if-status)
                  (let ((reason (detect-network-change last-if-status last-if-ip last-tick
                                                       now cur-if-status cur-if-ip)))
                    (setf last-if-status cur-if-status last-if-ip cur-if-ip last-tick now)
                    (cond
                      ;; Network changed AND we landed on "active": this is the
                      ;; moment reconnect actually happened (coming back from
                      ;; wifi-off, sleep/wake, or a different network). Going
                      ;; the other way — active -> inactive — has nothing to
                      ;; fix: there's no gateway to capture with the interface
                      ;; down, so a reconfigure attempt would just fail (or
                      ;; churn sing-box/tun2socks for nothing) and get redone
                      ;; a moment later anyway when the interface comes back.
                      ((and reason (string= cur-if-status "active") (eq *regime* :tunnel))
                       (full-reconfigure reason)
                       (setf fail-count 0 ok-count 0))
                      ;; Network changed but either we're in :direct fallback
                      ;; (nothing of ours is up to restart — let the normal
                      ;; revive-check below keep doing its job) or the
                      ;; interface just went inactive (nothing to fix yet).
                      (reason
                       (format t "~&[dog] network change (~a) noted, not reconfiguring~%" reason))
                      ;; No network change this tick: normal proxy-liveness regime.
                      (t
                       (ecase *regime*
                         (:tunnel
                          (if (server-alive-p)
                              (setf fail-count 0)
                              (progn
                                (incf fail-count)
                                (format t "~&[dog] server unreachable ~a/~a~%"
                                        fail-count *fail-threshold*)
                                (when (>= fail-count *fail-threshold*)
                                  (format t "~&[dog] server presumed dead, falling back to direct~%")
                                  (ignore-errors (stop-full))
                                  (setf fail-count 0 ok-count 0)
                                  (setf *regime* :direct)))))
                         (:direct
                          (if (server-alive-p)
                              (progn
                                (incf ok-count)
                                (format t "~&[dog] server responding again ~a/~a~%"
                                        ok-count *revive-threshold*)
                                (when (>= ok-count *revive-threshold*)
                                  (format t "~&[dog] server revived, restoring tunnel~%")
                                  (ignore-errors (start-full))
                                  (setf fail-count 0 ok-count 0)
                                  (setf *regime* :tunnel)))
                              (setf ok-count 0))))))))))))))

;;; --- control ---

(defun watch ()
  (when (and *thread* (sb-thread:thread-alive-p *thread*))
    (format t "~&Already watching~%")
    (return-from watch))
  (setf *regime* :tunnel)
  (setf *running* t)
  (setf *thread*
        (sb-thread:make-thread #'cycle :name "dog"))
  (format t "~&Watching started~%"))

(defun unwatch ()
  (setf *running* nil)
  (format t "~&Watching stopping (will exit after current sleep)~%"))

(defun watch? ()
  (multiple-value-bind (if-status ip) (if-status)
    (format t "~&Regime: ~a~%Running: ~a~%Watching: ~a:~a~%Interface: ~a (status ~a, ip ~a)~%"
            *regime*
            (and *thread* (sb-thread:thread-alive-p *thread*))
            *proxy-server-ip* *proxy-server-port*
            *watched-interface* if-status ip)))

;;; --- the one entry point ---

(defun connect ()
  "(load \"dog.lisp\") (connect) — the whole thing: sing-box, tun2socks,
   routes, and the watcher thread. Nothing else to load or call by hand."
  (start-full)
  (watch))

(defun disconnect ()
  "Inverse of connect. unwatch only flips a flag — the watcher thread
   might be mid-iteration and could still be running its own stop-full/
   start-full right now. Join it first, so this thread's stop-full below
   can never run concurrently with one from the watcher thread."
  (unwatch)
  (when (and *thread* (sb-thread:thread-alive-p *thread*))
    (sb-thread:join-thread *thread* :default nil))
  (stop-full))
