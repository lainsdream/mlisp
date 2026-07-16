;;;; server.lisp -- local web UI for xray speed tests
;;;; Start with: sbcl --load server.lisp

(defpackage :lserver
  (:use :cl))
(in-package :lserver)

(defparameter *server-directory*
  (make-pathname :directory (pathname-directory
                             (or *load-truename* *default-pathname-defaults*))))

;; The two files are kept separate so the command-line runner remains usable.
(load (merge-pathnames "speedtest-configs.lisp" *server-directory*))
(load (merge-pathnames "io.lisp" *server-directory*))

(defparameter *speedtest-jobs* 1)
(defvar *speedtest-stop-requested* nil)

(defun read-file-as-string (pathname)
  (with-open-file (in pathname :external-format :utf-8)
    (let* ((length (file-length in))
           (buffer (make-string length)))
      (subseq buffer 0 (read-sequence buffer in)))))

(defparameter *speedtest-js*
  (read-file-as-string (merge-pathnames "speedtest.js" *server-directory*))
  "Loaded once at startup; edit speedtest.js and restart the server to pick up changes.")

(defparameter *speedtest-html*
  (read-file-as-string (merge-pathnames "index.html" *server-directory*))
  "Loaded once at startup; edit index.html and restart the server to pick up changes.")

(defun write-http-response (stream status content-type body)
  ;; No Content-Length: BODY contains UTF-8 text, while STRING length is characters.
  (format stream "HTTP/1.1 ~a~C~CContent-Type: ~a~C~CConnection: close~C~C~C~C~a"
          status #\Return #\Linefeed content-type #\Return #\Linefeed
          #\Return #\Linefeed #\Return #\Linefeed body)
  (force-output stream))

(defun read-http-headers (stream)
  (loop for line = (read-line stream nil nil)
        while (and line (plusp (length (string-trim '(#\Return) line))))
        collect (let ((colon (position #\: line)))
                  (and colon
                       (cons (string-downcase (subseq line 0 colon))
                             (string-trim '(#\Space #\Tab #\Return)
                                          (subseq line (1+ colon))))))))

(defun header-value (headers name)
  (cdr (assoc name headers :test #'string=)))

(defun request-form-url (stream headers)
  (let* ((length-text (header-value headers "content-length"))
         (length (and length-text (parse-integer length-text :junk-allowed t))))
    (unless (and length (<= 1 length 4096))
      (error "Missing or unreasonable request body"))
    (let ((body (make-string length)))
      (read-sequence body stream)
      (qval (parse-query body) "url"))))

(defun valid-source-url-p (url)
  (and url
       (or (and (>= (length url) 7) (string-equal "http://" url :end2 7))
           (and (>= (length url) 8) (string-equal "https://" url :end2 8)))))

(defun write-sse (stream lock event payload)
  (sb-thread:with-mutex (lock)
    (format stream "event: ~a~%data: ~a~%~%" event (json-to-string payload))
    (force-output stream)))

(defun result-event-payload (result)
  (let ((cfg (getf result :cfg)))
    (list :obj
          (cons "mbps" (format nil "~,2f" (getf result :mbps)))
          (cons "tag" (proxy-config-tag cfg))
          (cons "kind" (string-downcase (symbol-name (proxy-config-kind cfg))))
          (cons "host" (proxy-config-host cfg))
          (cons "port" (proxy-config-port cfg))
          (cons "uri" (getf result :uri)))))

(defun stream-speedtest (stream url)
  "Read URL, then send valid test results as SSE events while workers finish."
  (let ((output-lock (sb-thread:make-mutex :name "sse-output")))
    (write-sse stream output-lock "status"
               (list :obj (cons "message" "Загружаю список конфигов…")))
    (handler-case
        (let* ((uris (read-uris-from-url url))
               (total (length uris))
               (queue uris)
               (queue-lock (sb-thread:make-mutex :name "speedtest-queue"))
               (done 0))
          (if (zerop total)
              (write-sse stream output-lock "error"
                         (list :obj (cons "message" "В файле не найдено конфигов.")))
              (progn
                (write-sse stream output-lock "status"
                           (list :obj
                                 (cons "message"
                                       (format nil "Найдено ~a конфигов; начинаю проверку…" total))))
                (labels ((next-uri ()
                           (sb-thread:with-mutex (queue-lock) (pop queue)))
                         (completed ()
                           (sb-thread:with-mutex (queue-lock) (incf done)))
                         (make-worker ()
                           (sb-thread:make-thread
                            (lambda ()
                              (loop while (not *speedtest-stop-requested*)
                                    for uri = (next-uri)
                                    while uri
                                    do (let ((result
                                               (handler-case
                                                   (test-one-config uri :verbose nil)
                                                 (error () nil))))
                                         (when (and result (eq (getf result :status) :ok))
                                           (ignore-errors
                                            (write-sse stream output-lock "result"
                                                       (result-event-payload result))))
                                         (write-sse stream output-lock "progress"
                                                    (list :obj
                                                          (cons "done" (completed))
                                                          (cons "total" total))))))
                            :name "web-speedtest")))
                  (let ((workers (loop repeat (min *speedtest-jobs* total)
                                       collect (make-worker))))
                    (dolist (worker workers)
                      (sb-thread:join-thread worker))
                    (write-sse stream output-lock "status"
                               (list :obj (cons "message" "Проверка завершена."))))))))
      (error (condition)
        (write-sse stream output-lock "error"
                   (list :obj
                         (cons "message"
                               (format nil "Не удалось загрузить список: ~a" condition))))))))

(defun parse-request-line (line)
  (let ((first-space (position #\Space line)))
    (when first-space
      (let ((second-space (position #\Space line :start (1+ first-space))))
        (when second-space
          (values (subseq line 0 first-space)
                  (subseq line (1+ first-space) second-space)))))))

(defun handle-request (stream)
  (let ((line (read-line stream nil "")))
    (multiple-value-bind (method path) (parse-request-line line)
      (let ((headers (read-http-headers stream)))
        (cond
          ((and (string= method "GET") (string= path "/"))
           (write-http-response stream "200 OK" "text/html; charset=utf-8" *speedtest-html*))
          ((and (string= method "GET") (string= path "/speedtest.js"))
           (write-http-response stream "200 OK" "application/javascript; charset=utf-8" *speedtest-js*))
          ((and (string= method "POST") (string= path "/speedtest"))
           (handler-case
               (let ((url (request-form-url stream headers)))
                 (if (valid-source-url-p url)
                     (progn
                       (format stream "HTTP/1.1 200 OK~C~CContent-Type: text/event-stream~C~CCache-Control: no-cache~C~CConnection: close~C~C~C~C"
                               #\Return #\Linefeed #\Return #\Linefeed #\Return #\Linefeed
                               #\Return #\Linefeed #\Return #\Linefeed)
                       (force-output stream)
                       (stream-speedtest stream url))
                     (write-http-response stream "400 Bad Request" "text/plain; charset=utf-8"
                                          "Expected an http:// or https:// URL.")))
             (error (condition)
               (write-http-response stream "400 Bad Request" "text/plain; charset=utf-8"
                                    (format nil "Bad request: ~a" condition)))))
          (t
           (write-http-response stream "404 Not Found" "text/plain; charset=utf-8" "Not found.")))))))

(defvar *server-socket* nil)

(defun start-simple-server (&optional (port 4242))
  (setf *speedtest-stop-requested* nil)
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf *server-socket* socket)
    (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
    (sb-bsd-sockets:socket-bind socket #(127 0 0 1) port)
    (sb-bsd-sockets:socket-listen socket 16)
    (format t "Speedtest server started on http://127.0.0.1:~a/~%" port)
    (handler-case
        (loop
          (let ((client (sb-bsd-sockets:socket-accept socket)))
            (sb-thread:make-thread
             (lambda ()
               (unwind-protect
                    (let ((stream (sb-bsd-sockets:socket-make-stream client :input t :output t)))
                      (unwind-protect (handle-request stream) (close stream)))
                 (sb-bsd-sockets:socket-close client)))
             :name "http-client")))
      (sb-bsd-sockets:socket-error ()
        (format t "Server stopped.~%")))))

(defun stop ()
  (setf *speedtest-stop-requested* t)
  (when *server-socket*
    (sb-bsd-sockets:socket-close *server-socket*)
    (setf *server-socket* nil)
    (format t "Speedtest server stopped.~%")))

(start-simple-server 4242)
