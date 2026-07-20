;;; tun-ctl.lisp — добавляется поверх твоего singbox-ctl.lisp
(defparameter *priv-helper-bin* "/usr/local/libexec/lisp-vpn-priv")
(defparameter *tun-name* "utun9")           ; можно любое свободное имя
(defparameter *tun-ip* "198.18.0.1/15")     ; произвольная приватная подсеть, не пересекающаяся с локальной сетью
(defparameter *proxy-server-ip* "82.38.31.149") ; IP твоего shadowsocks-сервера — ВАЖНО его исключить из туннеля
(defparameter *original-gateway* nil)

;; --- узнать текущий default gateway, чтобы потом восстановить ---
;; Остаётся непривилегированным: это только чтение состояния, ничего не меняет.
(defun capture-original-route ()
  (let ((output (with-output-to-string (s)
                  (sb-ext:run-program "/sbin/route" (list "-n" "get" "default")
                                      :output s :wait t))))
    (let ((line (find-if (lambda (l) (search "gateway:" l))
                         (uiop:split-string output :separator '(#\Newline)))))
      (setf *original-gateway*
            (string-trim " " (second (uiop:split-string line :separator '(#\:))))))
    (format t "~&Original gateway: ~a~%" *original-gateway*)))

;; --- единая точка вызова root-хелпера lisp-vpn-priv ---
(defun privileged (&rest arguments)
  (let ((proc (sb-ext:run-program "/usr/bin/sudo"
                                  (append (list "-n" *priv-helper-bin*) arguments)
                                  :output *standard-output* :error :output
                                  :input nil :wait t)))
    (unless (zerop (sb-ext:process-exit-code proc))
      (error "lisp-vpn-priv failed: ~{~a~^ ~}" arguments))))

;; --- исключить IP прокси-сервера из туннеля, чтобы не было петли ---
(defun exclude-proxy-server ()
  (privileged "add-proxy-route" *proxy-server-ip* *original-gateway*))

;; --- сделать TUN-интерфейс default route ---
(defun set-default-route ()
  (privileged "enable-tun-default"))

;; --- откат ---
(defun restore-route ()
  ;; Do not invent a gateway. A missing captured gateway is an error.
  (unless *original-gateway*
    (error "Cannot restore route: original gateway was never captured"))
  ;; unwind-protect: даже если restore-default упадёт, всё равно пробуем
  ;; убрать host-route для прокси-сервера, чтобы частичный сбой не оставлял
  ;; его висеть. ignore-errors на очистке — чтобы неудачный cleanup не
  ;; маскировал исходную ошибку restore-default.
  (unwind-protect
       (privileged "restore-default" *original-gateway*)
    (when *proxy-server-ip*
      (ignore-errors (privileged "remove-proxy-route" *proxy-server-ip*)))))

(defun assign-tun-ip ()
  (privileged "assign-tun" *tun-name*))

;; --- запустить tun2socks ---
(defun start-tun ()
  (privileged "start-tun" *tun-name*)
  (format t "~&tun2socks started~%")
  (sleep 2))

(defun stop-tun ()
  (restore-route)
  (privileged "stop-tun")
  (format t "~&Routes restored~%"))

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
