(defparameter *setsid-bin* "/opt/homebrew/opt/util-linux/bin/setsid")
(defparameter *singbox-bin* "/opt/homebrew/bin/sing-box")
(defparameter *config-path* "/tmp/ss-config.json")
(defparameter *log-path* "/tmp/singbox.log")
(defparameter *process* nil)

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
  (format t "~&Started, pid ~a~%" (sb-ext:process-pid *process*)))

(defun find-and-kill-by-name (name)
  (let ((output (with-output-to-string (s)
                  (ignore-errors
                   (sb-ext:run-program "/usr/bin/pgrep" (list "-f" name)
                                       :output s :wait t)))))
    (dolist (line (uiop:split-string output :separator '(#\Newline)))
      (let ((pid (string-trim '(#\Space #\Return) line)))
        (when (plusp (length pid))
          (sb-ext:run-program "/usr/bin/sudo" (list "-n" "kill" "-9" pid)
                              :input nil :wait t))))))

(defun stop ()
  (find-and-kill-by-name "sing-box run")
  (setf *process* nil)
  (format t "~&Stopped~%"))

(defun status ()
  (if (and *process* (sb-ext:process-alive-p *process*))
      (format t "~&Running, pid ~a~%" (sb-ext:process-pid *process*))
      (format t "~&Not running~%")))
