;;;; server.lisp -- local web UI for xray speed tests
;;;; Start with: sbcl --load server.lisp

(defparameter *server-directory*
  (make-pathname :directory (pathname-directory
                             (or *load-truename* *default-pathname-defaults*))))

;; The two files are kept separate so the command-line runner remains usable.
(load (merge-pathnames "test.lisp" *server-directory*))

(defparameter *speedtest-jobs* 8
  "Max concurrent config tests. Two separate ceilings to balance:
1) External speedtest endpoints (*test-urls* / *stability-urls*) -- too many
   parallel workers hitting them raised 429s before URI de-duplication cut
   most of the redundant same-host traffic. De-duped, this is now unlikely
   at this worker count.
2) The local uplink/downlink itself -- every worker's download shares the
   *same* physical connection regardless of which proxy exit it goes
   through, so too many workers understate every config's real speed (and
   can inflate jitter from local congestion, not the proxy). Top speeds
   held steady (77-84 Mbps) with no decay across a full run at 5 workers
   on a confirmed 150-300 Mbps-class connection, so 8 has headroom; if top
   speeds start looking suspiciously lower than what you've already seen
   at a lower worker count, that's the signal to back off, not any error
   message. Console output is now buffered per-config and flushed
   atomically (see *CONSOLE-LOCK*), so the log stays readable at this
   worker count for judging whether failures cluster (contention) or
   stay spread out (source subscription just has a lot of dead nodes).")
(defvar *speedtest-stop-requested* nil)

(defvar *log-stream* nil
  "*STANDARD-OUTPUT* captured at the moment (start) is called. Background
threads (http-client, web-speedtest) don't inherit SLIME/swank's per-connection
stream redirection the way the thread that types at the REPL does, so
without rebinding to this explicitly, their FORMAT T output either vanishes
or goes to the raw terminal the Lisp process was launched from instead of
your SLIME REPL buffer.")
(defvar *log-error-stream* nil "Same idea as *LOG-STREAM*, for *ERROR-OUTPUT*.")

(defmacro with-captured-output (&body body)
  "Rebind *STANDARD-OUTPUT*/*ERROR-OUTPUT* to the streams captured by START,
so FORMAT T calls inside BODY (which runs in its own thread) show up in the
same place your (start) call's output did."
  `(let ((*standard-output* (or *log-stream* *standard-output*))
         (*error-output* (or *log-error-stream* *error-output*)))
     ,@body))

  ;;; ---------------------------------------------------------------------
  ;;; I/O helpers
  ;;; ---------------------------------------------------------------------

(defparameter *uri-trim-chars*
  '(#\Space #\Tab #\Return))

(defun read-uris-from-stream (stream)
  "Return trimmed non-empty, non-comment URI lines from STREAM."
  (loop for line = (read-line stream nil nil)
        while line
        for trimmed = (string-trim *uri-trim-chars* line)
        when (and (plusp (length trimmed))
                  (not (char= (char trimmed 0) #\;)))
        collect trimmed))

(defun read-uris-from-url (url)
  "Fetch URL via curl and return trimmed URI lines."
  (multiple-value-bind (code out err)
      (run-and-capture (list "curl" "-sS" "-L" url) :timeout 20)
    (unless (and (zerop code) out)
      (error "read-uris-from-url: curl failed (exit=~a): ~a"
             code err))
    (with-input-from-string (stream out)
      (read-uris-from-stream stream))))

(defun read-file-as-string (pathname)
  (with-open-file (in pathname :external-format :utf-8)
    (let* ((length (file-length in))
           (buffer (make-string length)))
      (subseq buffer 0 (read-sequence buffer in)))))

(defparameter *speedtest-js*
  (read-file-as-string (merge-pathnames "index.js" *server-directory*))
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
  "Write one SSE event. Returns T on success, NIL if the client is gone
(broken pipe / connection reset / etc) -- callers should stop trying to
write to STREAM after that instead of letting every subsequent write throw
and silently kill whatever thread is doing the writing."
  (sb-thread:with-mutex (lock)
    (handler-case
        (progn
          (format stream "event: ~a~%data: ~a~%~%" event (json-to-string payload))
          (force-output stream)
          t)
      (stream-error () nil)
      (error () nil))))

(defun result-event-payload (result)
  (let ((cfg (getf result :cfg))
        (stab (getf result :stability)))
    (list :obj
          (cons "mbps" (format nil "~,2f" (getf result :mbps)))
          (cons "tag" (proxy-config-tag cfg))
          (cons "kind" (string-downcase (symbol-name (proxy-config-kind cfg))))
          (cons "host" (proxy-config-host cfg))
          (cons "port" (proxy-config-port cfg))
          (cons "hostCountry" (or (getf result :host-country) ""))
          (cons "uri" (getf result :uri))
          (cons "exitIp" (or (getf result :exit-ip) ""))
          (cons "exitCountry" (or (getf result :exit-country) ""))
          (cons "multihop" (if (getf result :multihop-p) t :false))
          (cons "jitterMs" (format nil "~,0f" (or (getf stab :jitter-ms) 0.0d0)))
          (cons "failedProbes" (or (getf stab :failures) 0))
          (cons "totalProbes" (or (getf stab :rounds) 0)))))

(defun stream-speedtest (stream url)
  "Read URL, then send valid test results as SSE events while workers finish."
  (let ((output-lock (sb-thread:make-mutex :name "sse-output"))
        (client-alive t))
    (labels ((sse (event payload)
               ;; Once the browser side of this connection is gone (tab
               ;; closed, page reloaded, network blip), every further write
               ;; would throw. Stop writing -- and signal workers to stop
               ;; testing for THIS request -- instead of letting an
               ;; uncaught error kill whichever worker thread hits it next
               ;; and silently abandon the rest of the queue.
               (when client-alive
                 (unless (write-sse stream output-lock event payload)
                   (setf client-alive nil)))))
      (sse "status" (list :obj (cons "message" "Загружаю список конфигов…")))
      (handler-case
          (let* ((raw-uris (read-uris-from-url url)))
           (multiple-value-bind (uris duplicates) (dedupe-uris raw-uris)
            (let* ((total (length uris))
                   (queue uris)
                   (queue-lock (sb-thread:make-mutex :name "speedtest-queue"))
                   (done 0))
            (if (zerop total)
                (sse "error" (list :obj (cons "message" "В файле не найдено конфигов.")))
                (progn
                  (sse "status"
                       (list :obj
                             (cons "message"
                                   (if (plusp duplicates)
                                       (format nil "Найдено ~a конфигов (~a дублей отброшено); начинаю проверку…"
                                               total duplicates)
                                       (format nil "Найдено ~a конфигов; начинаю проверку…" total)))))
                  (labels ((next-uri ()
                             (sb-thread:with-mutex (queue-lock) (pop queue)))
                           (completed ()
                             (sb-thread:with-mutex (queue-lock) (incf done)))
                           (make-worker ()
                             (sb-thread:make-thread
                              (lambda ()
                                (with-captured-output
                                    (loop while (and client-alive (not *speedtest-stop-requested*))
                                          for uri = (next-uri)
                                          while uri
                                          do (let ((result
                                                     (handler-case
                                                         ;; :verbose t makes test-one-config print
                                                         ;; TCP/xray/download/stability failure reasons
                                                         ;; to *standard-output* -- i.e. the server's
                                                         ;; console/terminal, not the browser -- so you
                                                         ;; can see why a config was rejected.
                                                         (test-one-config uri :verbose t)
                                                       (error (c)
                                                         (format t "~&[speedtest] ~a -> unhandled error: ~a~%" uri c)
                                                         (force-output)
                                                         nil))))
                                               (when result
                                                 (case (getf result :status)
                                                   (:stable
                                                    (sse "result" (result-event-payload result)))
                                                   (:unstable
                                                    (sse "unstable-result" (result-event-payload result)))))
                                               (sse "progress"
                                                    (list :obj
                                                          (cons "done" (completed))
                                                          (cons "total" total)))))))
                              :name "web-speedtest")))
                    (let ((workers (loop repeat (min *speedtest-jobs* total)
                                         collect (make-worker))))
                      (dolist (worker workers)
                        (sb-thread:join-thread worker))
                      (sse "status" (list :obj (cons "message" "Проверка завершена."))))))))))
        (error (condition)
          (sse "error"
               (list :obj
                     (cons "message"
                           (format nil "Не удалось загрузить список: ~a" condition)))))))))

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

(defun stop ()
  (setf *speedtest-stop-requested* t)
  (when *server-socket*
    (ignore-errors (sb-bsd-sockets:socket-close *server-socket*))
    (setf *server-socket* nil)
    (format t "Speedtest server stopped.~%")))

(defun start (&optional (port 4242))
  ;; Reloading this file (e.g. via SLIME's C-c C-k) re-runs the (start) call
  ;; at the bottom every time. If a server from an earlier load is still
  ;; listening on the same port, binding a new socket to it fails with
  ;; EADDRINUSE -- so always tear down any previous instance from this image
  ;; first. This does NOT help if some *other* process (a stray SBCL, or
  ;; anything else) is holding the port; in that case you'll still get
  ;; EADDRINUSE and need to free the port yourself (or pass a different one).
  (stop)
  (setf *speedtest-stop-requested* nil)
  (setf *log-stream* *standard-output*)
  (setf *log-error-stream* *error-output*)
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
    (handler-case
        (sb-bsd-sockets:socket-bind socket #(127 0 0 1) port)
      (sb-bsd-sockets:socket-error (e)
        (ignore-errors (sb-bsd-sockets:socket-close socket))
        (error "Couldn't bind port ~a (~a). If nothing here already owns it, ~
something else does -- find and stop it (e.g. `lsof -iTCP:~a -sTCP:LISTEN` ~
in a terminal), or call (start ~a) with a different port." port e port (1+ port))))
    (setf *server-socket* socket)
    (sb-bsd-sockets:socket-listen socket 16)
    (format t "Speedtest server started on http://127.0.0.1:~a/~%" port)
    (handler-case
        (loop
          (let ((client (sb-bsd-sockets:socket-accept socket)))
            (sb-thread:make-thread
             (lambda ()
               (with-captured-output
                   (unwind-protect
                        (let ((stream (sb-bsd-sockets:socket-make-stream client :input t :output t)))
                          (unwind-protect (handle-request stream) (close stream)))
                     (sb-bsd-sockets:socket-close client))))
             :name "http-client")))
      (sb-bsd-sockets:socket-error ()
        (format t "Server stopped.~%")))))

(start)
