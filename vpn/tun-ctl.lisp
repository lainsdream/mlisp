;;; tun-ctl.lisp — добавляется поверх твоего singbox-ctl.lisp
(defparameter *priv-helper-bin* "/usr/local/libexec/lisp-vpn-priv")
(defparameter *tun-name* "utun9")           ; можно любое свободное имя
(defparameter *tun-ip* "198.18.0.1/15")     ; произвольная приватная подсеть, не пересекающаяся с локальной сетью
(defparameter *proxy-server-ip* "82.38.31.149") ; IP твоего shadowsocks-сервера — ВАЖНО его исключить из туннеля

;; Original gateway больше не живёт в Lisp вообще — ни как переменная, ни
;; как аргумент, который Lisp передаёт хелперу. lisp-vpn-priv сам читает
;; `route -n get default` в момент setup-routes, сам хранит результат в
;; root-owned /var/run/lisp-vpn-original-gw, и сам же его читает обратно
;; в teardown-routes. Lisp не может передать хелперу устаревший или
;; подделанный gateway, потому что он его никогда не держит в руках.

;; --- единая точка вызова root-хелпера lisp-vpn-priv ---
(defun privileged (&rest arguments)
  (let ((proc (sb-ext:run-program "/usr/bin/sudo"
                                  (append (list "-n" *priv-helper-bin*) arguments)
                                  :output *standard-output* :error :output
                                  :input nil :wait t)))
    (unless (zerop (sb-ext:process-exit-code proc))
      (error "lisp-vpn-priv failed: ~{~a~^ ~}" arguments))))

;; --- поднять маршруты: хост-роут на прокси в обход туннеля + default → TUN ---
;; Одна привилегированная операция вместо двух: хелпер сам захватывает
;; gateway, добавляет host-route и меняет default route, откатывая себя
;; сам при частичном сбое (см. lisp-vpn-priv.c). С точки зрения Lisp это
;; либо целиком получилось, либо целиком не изменило состояние машины.
(defun setup-routes ()
  (privileged "setup-routes" *proxy-server-ip*))

;; --- откат: default route обратно на исходный gateway + убрать host-route ---
(defun teardown-routes ()
  (privileged "teardown-routes" *proxy-server-ip*))

(defun assign-tun-ip ()
  (privileged "assign-tun" *tun-name*))

;; --- запустить tun2socks ---
(defun start-tun ()
  (privileged "start-tun" *tun-name*)
  (format t "~&tun2socks started~%")
  (sleep 2))

(defun stop-tun ()
  (privileged "stop-tun")
  (format t "~&tun2socks stopped~%"))

;; --- полный запуск: sing-box + tun2socks + routing ---
(defun start-full ()
  (start)
  (sleep 1)
  (start-tun)
  (sleep 2)
  (assign-tun-ip)
  (setup-routes)
  (format t "~&Full TUN setup complete~%"))

(defun stop-full ()
  (teardown-routes)
  (stop-tun)
  (stop)
  (format t "~&Routes restored~%"))
