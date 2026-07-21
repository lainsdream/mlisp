(defparameter *setsid-bin* "/opt/homebrew/opt/util-linux/bin/setsid")
(defparameter *singbox-bin* "/opt/homebrew/bin/sing-box")
(defparameter *config-path* "/tmp/ss-config.json")
(defparameter *log-path* "/tmp/singbox.log")
(defparameter *socks-port* 1080
  "Must match listen_port of the `mixed`/socks inbound in *config-path* —
   this is what we poll to decide sing-box is actually up.")
(defparameter *start-timeout* 10
  "Seconds to wait for sing-box's SOCKS port before giving up. Generous on
   purpose: a cold sing-box start (DNS resolution of the outbound server,
   TLS handshake setup, etc.) can occasionally take a couple of seconds,
   and a spurious timeout error is a much better failure mode than racing
   ahead with tun2socks/routes and only failing to make one clear.")
(defparameter *process* nil)

;; --- generic readiness polling, shared with tun-ctl.lisp ---
;;
;; Fixed (sleep N) before "the next step" is a race: N is a guess at how
;; long the external process needs to become ready, and it's either wasted
;; time (N too generous) or a silent failure later on (N too short, e.g. a
;; slow machine). wait-until polls for the actual condition instead, and
;; fails loudly with a clear message if it never becomes true, rather than
;; letting a caller two steps downstream (assign-tun/setup-routes) fail
;; with a confusing unrelated error.
(defun wait-until (predicate &key (timeout 10) (interval 0.2) description)
  "Poll PREDICATE every INTERVAL seconds until it returns true, or signal
   an error naming DESCRIPTION once TIMEOUT seconds have passed."
  (let ((deadline (+ (get-internal-real-time)
                      (round (* timeout internal-time-units-per-second)))))
    (loop
      (when (funcall predicate)
        (return t))
      (when (> (get-internal-real-time) deadline)
        (error "Timed out after ~as waiting for ~a"
               timeout (or description "condition")))
      (sleep interval))))

(defun port-open-p (host port)
  "True if something accepts a TCP connection on host:port right now.
   Short per-call timeout (1s) — this is meant to be polled repeatedly by
   wait-until, not used as a one-shot check."
  (zerop (sb-ext:process-exit-code
          (sb-ext:run-program "/usr/bin/nc"
                              (list "-z" "-w" "1" host (princ-to-string port))
                              :output nil :error nil :wait t))))

(defun start ()
  (when (and *process* (sb-ext:process-alive-p *process*))
    (format t "~&Already running~%")
    (return-from start))
  (setf *process*
        (sb-ext:run-program *setsid-bin*
                            (list *singbox-bin* "run" "-c" *config-path*)
                            :output *log-path*
                            :error :output
                            :if-output-exists :supersede
                            :wait nil))
  ;; NB: we deliberately do NOT also check (sb-ext:process-alive-p *process*)
  ;; here as a fail-fast signal. *process* is the *setsid* wrapper's PID —
  ;; setsid forks and exits almost immediately (see README, "setsid форкает,
  ;; а не exec'ает себя"), so process-alive-p on it is always NIL within
  ;; moments of starting, even when sing-box itself is running fine. The
  ;; SOCKS port is the only reliable signal we have.
  (wait-until (lambda () (port-open-p "127.0.0.1" *socks-port*))
              :timeout *start-timeout*
              :description (format nil "sing-box SOCKS port 127.0.0.1:~a (check ~a)"
                                    *socks-port* *log-path*))
  (format t "~&Started, pid ~a~%" (sb-ext:process-pid *process*)))

;; sing-box is launched above via an unprivileged *setsid-bin* call — it runs
;; as the current user, not root. Stopping it is therefore an ordinary
;; same-user kill and never needs sudo. This fallback only exists for the
;; case where the Lisp image was restarted and lost the *process* handle;
;; even then it kills as ourselves, never as root.
(defun find-and-kill-by-name (name)
  (let ((output (with-output-to-string (s)
                  (ignore-errors
                   (sb-ext:run-program "/usr/bin/pgrep" (list "-f" name)
                                       :output s :wait t)))))
    (dolist (line (uiop:split-string output :separator '(#\Newline)))
      (let ((pid (string-trim '(#\Space #\Return) line)))
        (when (plusp (length pid))
          (sb-ext:run-program "/bin/kill" (list "-9" pid)
                              :input nil :wait t))))))

(defun stop ()
  (if (and *process* (sb-ext:process-alive-p *process*))
      ;; Preferred path: we hold the exact process object we started,
      ;; so there's no PID-reuse ambiguity at all.
      (progn
        (sb-ext:process-kill *process* 9)
        (sb-ext:process-wait *process*))
      ;; Fallback path: Lisp image was restarted (handle lost), or sing-box
      ;; was started outside this session. Best effort, still unprivileged.
      (find-and-kill-by-name "sing-box run"))
  (setf *process* nil)
  (format t "~&Stopped~%"))

(defun status ()
  (if (and *process* (sb-ext:process-alive-p *process*))
      (format t "~&Running, pid ~a~%" (sb-ext:process-pid *process*))
      (format t "~&Not running~%")))
