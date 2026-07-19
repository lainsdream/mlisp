;;; tun-ctl.lisp — добавляется поверх твоего singbox-ctl.lisp
(defparameter *tun2socks-bin* "/usr/local/bin/tun2socks")
(defparameter *tun-process* nil)
(defparameter *tun-name* "utun9")           ; можно любое свободное имя
(defparameter *tun-ip* "198.18.0.1/15")     ; произвольная приватная подсеть, не пересекающаяся с локальной сетью
(defparameter *proxy-server-ip* "82.38.31.46") ; IP твоего shadowsocks-сервера — ВАЖНО его исключить из туннеля
(defparameter *original-gateway* nil)
(defparameter *original-interface* nil)

;; --- узнать текущий default gateway, чтобы потом восстановить ---
(defun capture-original-route ()
  (let ((output (with-output-to-string (s)
                  (sb-ext:run-program "/sbin/route" (list "-n" "get" "default")
                                      :output s :wait t))))
    (let ((line (find-if (lambda (l) (search "gateway:" l))
                         (uiop:split-string output :separator '(#\Newline)))))
      (setf *original-gateway*
            (string-trim " " (second (uiop:split-string line :separator '(#\:))))))
    (format t "~&Original gateway: ~a~%" *original-gateway*)))

;; --- исключить IP прокси-сервера из туннеля, чтобы не было петли ---
(defun exclude-proxy-server ()
  (sb-ext:run-program "/usr/bin/sudo"
                      (list "/sbin/route" "add" *proxy-server-ip* *original-gateway*)
                      :output *standard-output* :error :output :wait t))


;; --- назначить IP интерфейсу и сделать его default route ---
(defun set-default-route ()
  (sb-ext:run-program "/usr/bin/sudo" (list "/sbin/route" "delete" "default")
                      :output *standard-output* :error :output :wait t)
  (let ((proc (sb-ext:run-program "/usr/bin/sudo" (list "/sbin/route" "add" "default" "198.18.0.1")
                                  :output *standard-output* :error :output :wait t)))
    (unless (zerop (sb-ext:process-exit-code proc))
      (format t "~&WARNING: failed to set default route via TUN, restoring original~%")
      (sb-ext:run-program "/usr/bin/sudo" (list "/sbin/route" "add" "default" *original-gateway*)
                          :output *standard-output* :error :output :wait t))))

;; --- откат --
(defun restore-route ()
  (let ((gw (or *original-gateway* "192.168.0.1")))
    (sb-ext:run-program "/usr/bin/sudo" (list "/sbin/route" "delete" "default")
                        :output *standard-output* :error :output :wait t)
    (sb-ext:run-program "/usr/bin/sudo" (list "/sbin/route" "add" "default" gw)
                        :output *standard-output* :error :output :wait t)
    (when *proxy-server-ip*
      (sb-ext:run-program "/usr/bin/sudo" (list "/sbin/route" "delete" *proxy-server-ip*)
                          :output *standard-output* :error :output :wait t))))

(defun assign-tun-ip ()
  (sb-ext:run-program "/usr/bin/sudo"
                      (list "/sbin/ifconfig" *tun-name* "198.18.0.1" "198.18.0.1" "up")
                      :output *standard-output* :error :output :wait t))

(defun stop-tun ()
  (find-and-kill-by-name "tun2socks")
  (setf *tun-process* nil)
  (restore-route)
  (format t "~&Routes restored~%"))

;; --- запустить tun2socks ---
(defun start-tun ()
  (setf *tun-process*
        (sb-ext:run-program "/usr/bin/sudo"
                            (list *setsid-bin* *tun2socks-bin*
                                  "-d" (format nil "tun://~a" *tun-name*)
                                  "-p" "socks5://127.0.0.1:1080")
                            :output "/tmp/tun2socks.log"
                            :error :output
                            :input nil
                            :if-output-exists :supersede
                            :wait nil))
  (format t "~&tun2socks started, pid ~a~%" (sb-ext:process-pid *tun-process*))
  (sleep 2))

;; --- полный запуск: sing-box + tun2socks + routing ---
(defun start-full ()
  (start)
  (sleep 1)
  (capture-original-route)
  (exclude-proxy-server)
  (start-tun)
  (sleep 2)
  (assign-tun-ip)
  (set-default-route)
  (format t "~&Full TUN setup complete~%"))

(defun stop-full ()
  (stop-tun)
  (stop))
