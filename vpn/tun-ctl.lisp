;;; tun-ctl.lisp — добавляется поверх твоего singbox-ctl.lisp
(defparameter *priv-helper-bin* "/usr/local/libexec/lisp-vpn-priv")
(defparameter *tun-name* "utun9")           ; можно любое свободное имя
;; Раньше здесь был *tun-ip* — удалён: он нигде не читался, assign-tun-ip
;; передаёт хелперу только *tun-name*, а реальная подсеть TUN (198.18.0.1)
;; зашита в lisp-vpn-priv.c как TUN_IP. Поменять её можно только там, с
;; пересборкой хелпера — Lisp-переменная этого не делала, только вводила
;; в заблуждение.
(defparameter *proxy-server-ip* nil
  "IP текущего активного сервера — ВАЖНО исключить его из туннеля
   host-route'ом. Само значение сюда не хардкодится: dog.lisp
   перезаписывает его через (setf *proxy-server-ip* ...) в
   switch-to-config при каждом переключении на новый пул-энтри, ещё до
   первого start-full. Переменная объявлена здесь как special var,
   потому что setup-routes/teardown-routes в этом файле — единственные
   её потребители.")
(defparameter *tun-start-timeout* 10
  "Seconds to wait for the TUN interface to actually appear after
   start-tun. lisp-vpn-priv's start-tun subcommand spawns tun2socks via
   setsid in the background and returns as soon as it's launched, not
   once the interface exists — so `privileged` returning is not itself a
   readiness signal, same reasoning as sing-box's SOCKS port in
   singbox-ctl.lisp.")

;; Original gateway больше не живёт в Lisp вообще — ни как переменная, ни
;; как аргумент, который Lisp передаёт хелперу. lisp-vpn-priv сам читает
;; `route -n get default` в момент setup-routes, сам хранит результат в
;; root-owned /var/run/lisp-vpn-original-gw, и сам же его читает обратно
;; в teardown-routes. Lisp не может передать хелперу устаревший или
;; подделанный gateway, потому что он его никогда не держит в руках.

(defun tun-interface-up-p (name)
  "True once NAME shows up as a real interface via ifconfig — this is the
   actual readiness signal for start-tun, polled by wait-until (defined in
   singbox-ctl.lisp, loaded before this file) instead of guessing with a
   fixed sleep."
  (zerop (sb-ext:process-exit-code
          (sb-ext:run-program "/sbin/ifconfig" (list name)
                              :output nil :error nil :wait t))))

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
  (wait-until (lambda () (tun-interface-up-p *tun-name*))
              :timeout *tun-start-timeout*
              :description (format nil "TUN interface ~a to appear" *tun-name*))
  (format t "~&tun2socks started~%"))

(defun stop-tun ()
  (privileged "stop-tun")
  (format t "~&tun2socks stopped~%"))

;; --- полный запуск: sing-box + tun2socks + routing ---
(defun start-full ()
  (start)
  (start-tun)
  (assign-tun-ip)
  (setup-routes)
  (format t "~&Full TUN setup complete~%"))

(defun stop-full ()
  (teardown-routes)
  (stop-tun)
  (stop)
  (format t "~&Routes restored~%"))
