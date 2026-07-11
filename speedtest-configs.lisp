;;;; speedtest-configs.lisp
;;;;
;;;; Takes a list of vless:// and ss:// config URIs, filters the ones that
;;;; pass a raw TCP connect test, then for the survivors spins up a real
;;;; xray-core instance (local SOCKS5 inbound + the config as outbound),
;;;; downloads a test file through it, measures throughput, tears the
;;;; process down, and ranks configs by real measured speed.
;;;;
;;;; Requires: an `xray` binary on PATH (or set *xray-path*).
;;;; Only orchestrates xray-core -- does not reimplement VLESS/SS protocols.

(require :sb-bsd-sockets)
(require :sb-posix)

(defparameter *xray-path* "/opt/homebrew/bin/xray")
(defparameter *test-urls*
  '(
    "https://speed.cloudflare.com/__down?bytes=10000000"
    "https://proof.ovh.net/files/10Mb.dat"
                                        ;"https://speed.hetzner.de/10MB.bin"
    ))
(defparameter *download-timeout* 5)  ; seconds per config
(defparameter *script-dir* (make-pathname :directory (pathname-directory (or *load-truename* *default-pathname-defaults*))))

  ;;; ---------------------------------------------------------------------
  ;;; Small string / base64 helpers (no external deps)
  ;;; ---------------------------------------------------------------------

(defparameter *b64-table*
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun b64-decode (str)
  "Minimal base64 decoder, tolerant of missing padding and url-safe chars."
  (let* ((str  (substitute #\+ #\- (substitute #\/ #\_ str)))
         (str  (remove #\= str))
         (bits 0) (nbits 0)
         (out  (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
    (loop for ch across str
          for idx = (position ch *b64-table*)
          when idx do
          (setf bits (logior (ash bits 6) idx))
          (incf nbits 6)
          (when (>= nbits 8)
            (decf nbits 8)
            (vector-push-extend (code-char (logand (ash bits (- nbits)) #xFF)) out)))
    (coerce out 'simple-string)))

(defun url-decode (str)
  "Decode %XX percent-escapes as UTF-8 byte sequences; pass through any
   already-literal (non-percent-encoded) characters unchanged."
  (let ((out     (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
        (pending (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (flet ((flush-pending ()
             (when (> (length pending) 0)
               (loop for ch across (sb-ext:octets-to-string
                                    (coerce pending '(simple-array (unsigned-byte 8) (*)))
                                    :external-format :utf-8)
                     do (vector-push-extend ch out))
               (setf (fill-pointer pending) 0))))
      (loop with i = 0
            while (< i (length str))
            do (let ((ch (char str i)))
                 (cond
                   ((and (char= ch #\%) (< (+ i 2) (length str))
                         (digit-char-p (char str (1+ i)) 16)
                         (digit-char-p (char str (+ i 2)) 16))
                    (vector-push-extend (parse-integer str :start (1+ i) :end (+ i 3) :radix 16)
                                        pending)
                    (incf i 3))
                   (t
                    (flush-pending)
                    (vector-push-extend ch out)
                    (incf i)))))
      (flush-pending))
    (coerce out 'simple-string)))

(defun split-once (str ch)
  "Split STR at first CH. Returns (values before after) or (values str nil)."
  (let ((pos (position ch str)))
    (if pos (values (subseq str 0 pos) (subseq str (1+ pos)))
        (values str nil))))

(defun split-last (str ch)
  "Split STR at last CH."
  (let ((pos (position ch str :from-end t)))
    (if pos (values (subseq str 0 pos) (subseq str (1+ pos)))
        (values str nil))))

(defun file-tag (path-or-url)
  "Extract base filename without extension from a path or URL,
     e.g. '.../subscriptions/1.txt' -> \"1\"."
  (let* ((last-slash (position #\/ path-or-url :from-end t))
         (fname      (if last-slash (subseq path-or-url (1+ last-slash)) path-or-url))
         (dot        (position #\. fname :from-end t)))
    (if dot (subseq fname 0 dot) fname)))

(defun str-split (str ch)
  "Split STR on every occurrence of CH; returns list of substrings."
  (loop with start = 0
        for pos = (position ch str :start start)
        collect (subseq str start pos)
        while pos do (setf start (1+ pos))))

(defun parse-query (qs)
  "Parse 'a=b&c=d' query string into an alist of (key . value) strings."
  (when (and qs (> (length qs) 0))
    (loop for pair in (str-split qs #\&)
          for (k v) = (multiple-value-list (split-once pair #\=))
          collect (cons k (url-decode (or v ""))))))

(defun qval (alist key &optional default)
  (or (cdr (assoc key alist :test #'string=)) default))

  ;;; ---------------------------------------------------------------------
  ;;; JSON writer (tiny, just enough for xray config)
  ;;; ---------------------------------------------------------------------

(defun json-escape-string (s)
  "Return S with JSON-special chars escaped (no surrounding quotes)."
  (with-output-to-string (out)
    (loop for ch across s do
          (case ch
            (#\"      (write-string "\\\"" out))
            (#\\      (write-string "\\\\" out))
            (#\Newline (write-string "\\n"  out))
            (#\Return  (write-string "\\r"  out))
            (#\Tab     (write-string "\\t"  out))
            (t         (write-char ch out))))))

(defun json-write (obj &optional (stream *standard-output*))
  "OBJ: (:obj (k . v) ...) | (:arr v ...) | string | number | T | :false | :null"
  (cond
    ((eq obj :null)  (write-string "null"  stream))
    ((eq obj t)      (write-string "true"  stream))
    ((eq obj :false) (write-string "false" stream))
    ((numberp obj)   (princ obj stream))
    ((stringp obj)
     (write-char #\" stream)
     (write-string (json-escape-string obj) stream)
     (write-char #\" stream))
    ((and (consp obj) (eq (car obj) :obj))
     (write-char #\{ stream)
     (loop for (k . v) in (cdr obj)
           for first = t then nil
           do (unless first (write-char #\, stream))
              (write-char #\" stream)
              (write-string (json-escape-string k) stream)
              (write-char #\" stream)
              (write-char #\: stream)
              (json-write v stream))
     (write-char #\} stream))
    ((and (consp obj) (eq (car obj) :arr))
     (write-char #\[ stream)
     (loop for v in (cdr obj)
           for first = t then nil
           do (unless first (write-char #\, stream))
              (json-write v stream))
     (write-char #\] stream))
    (t (error "bad json obj: ~s" obj))))

(defun json-to-string (obj)
  (with-output-to-string (s) (json-write obj s)))

  ;;; ---------------------------------------------------------------------
  ;;; Config URI parsing
  ;;; ---------------------------------------------------------------------

(defstruct proxy-config
  kind        ; :vless | :shadowsocks
  tag         ; display name (fragment or host)
  uuid        ; vless only
  method      ; ss only
  password    ; ss only
  host port
  raw         ; original URI
  extra)      ; query-string alist

(defun strip-fragment (uri)
  "Return (values uri-without-fragment fragment-or-nil)."
  (multiple-value-bind (before after) (split-once uri #\#)
    (values before (and after (url-decode after)))))

(defun parse-vless (uri)
  (multiple-value-bind (body name) (strip-fragment uri)
    (let* ((body   (subseq body (length "vless://")))
           (at-pos (position #\@ body)))
      (unless at-pos (error "vless: no @ in ~a" uri))
      (let ((uuid (subseq body 0 at-pos))
            (rest (subseq body (1+ at-pos))))
        (multiple-value-bind (hostport query) (split-once rest #\?)
          (multiple-value-bind (host port-str) (split-last hostport #\:)
            (unless port-str (error "vless: no port in ~a" uri))
            (make-proxy-config
             :kind  :vless
             :tag   (or name host)
             :uuid  uuid
             :host  host
             :port  (or (parse-integer port-str :junk-allowed t)
                        (error "vless: bad port ~s" port-str))
             :raw   uri
             :extra (parse-query query))))))))

(defun parse-shadowsocks (uri)
  (multiple-value-bind (body name) (strip-fragment uri)
    (let ((body (subseq body (length "ss://"))))
      (multiple-value-bind (userinfo hostport) (split-once body #\@)
        (if hostport
            ;; modern:  ss://[base64(method:pass) | method:pass]@host:port[?query]
            (let* ((decoded (if (position #\: userinfo)
                                userinfo
                                (b64-decode userinfo))))
              (multiple-value-bind (method password) (split-once decoded #\:)
                (multiple-value-bind (hp _q) (split-once hostport #\?)
                  (declare (ignore _q))
                  (multiple-value-bind (host port-str) (split-last hp #\:)
                    (make-proxy-config
                     :kind     :shadowsocks
                     :tag      (or name host)
                     :method   method
                     :password password
                     :host     host
                     :port     (or (parse-integer port-str :junk-allowed t)
                                   (error "ss: bad port in ~a" uri))
                     :raw      uri
                     :extra    nil)))))
            ;; legacy: ss://BASE64(method:password@host:port)
            (let ((decoded (b64-decode body)))
              (multiple-value-bind (userinfo hp) (split-once decoded #\@)
                (multiple-value-bind (method password) (split-once userinfo #\:)
                  (multiple-value-bind (host port-str) (split-last hp #\:)
                    (make-proxy-config
                     :kind     :shadowsocks
                     :tag      (or name host)
                     :method   method
                     :password password
                     :host     host
                     :port     (or (parse-integer port-str :junk-allowed t)
                                   (error "ss(b64): bad port in ~a" uri))
                     :raw      uri
                     :extra    nil))))))))))

(defun parse-config-uri (uri)
  (let ((uri (string-trim '(#\Space #\Newline #\Return #\Tab) uri)))
    (cond
      ((and (>= (length uri) 8) (string= uri "vless://" :end1 8))
       (parse-vless uri))
      ((and (>= (length uri) 5) (string= uri "ss://" :end1 5))
       (parse-shadowsocks uri))
      (t nil))))

  ;;; ---------------------------------------------------------------------
  ;;; xray-core JSON config builder
  ;;; ---------------------------------------------------------------------

(defun free-local-port ()
  "Ask the OS for a free TCP port."
  (let ((sock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address sock) t)
    (sb-bsd-sockets:socket-bind sock #(127 0 0 1) 0)
    (let ((port (nth-value 1 (sb-bsd-sockets:socket-name sock))))
      (sb-bsd-sockets:socket-close sock)
      port)))

(defun stream-settings (cfg)
  (let* ((extra    (proxy-config-extra cfg))
         (network  (qval extra "type"     "tcp"))
         (security (qval extra "security" "none"))
         (fields   (list (cons "network" network))))
    ;; security layer
    (cond
      ((string= security "tls")
       (push (cons "security" "tls") fields)
       (push (cons "tlsSettings"
                   (list :obj
                         (cons "serverName"    (qval extra "sni" (proxy-config-host cfg)))
                         (cons "allowInsecure" :false)))
             fields))
      ((string= security "reality")
       (push (cons "security" "reality") fields)
       (push (cons "realitySettings"
                   (list :obj
                         (cons "serverName"  (qval extra "sni" ""))
                         (cons "fingerprint" (qval extra "fp"  "chrome"))
                         (cons "publicKey"   (qval extra "pbk" ""))
                         (cons "shortId"     (qval extra "sid" ""))))
             fields)))
    ;; transport layer
    (cond
      ((string= network "ws")
       (push (cons "wsSettings"
                   (list :obj
                         (cons "path"    (qval extra "path" "/"))
                         (cons "headers" (list :obj
                                               (cons "Host"
                                                     (qval extra "host"
                                                           (proxy-config-host cfg)))))))
             fields))
      ((string= network "grpc")
       (push (cons "grpcSettings"
                   (list :obj (cons "serviceName" (qval extra "serviceName" ""))))
             fields)))
    (cons :obj fields)))

(defun build-xray-config (cfg socks-port)
  (let ((outbound
          (ecase (proxy-config-kind cfg)
            (:vless
             (list :obj
                   (cons "protocol" "vless")
                   (cons "settings"
                         (list :obj
                               (cons "vnext"
                                     (list :arr
                                           (list :obj
                                                 (cons "address" (proxy-config-host cfg))
                                                 (cons "port"    (proxy-config-port cfg))
                                                 (cons "users"
                                                       (list :arr
                                                             (list :obj
                                                                   (cons "id"         (proxy-config-uuid cfg))
                                                                   (cons "encryption" "none")
                                                                   (cons "flow"
                                                                         (qval (proxy-config-extra cfg)
                                                                               "flow" ""))))))))))
                   (cons "streamSettings" (stream-settings cfg))
                   (cons "tag" "proxy")))
            (:shadowsocks
             (list :obj
                   (cons "protocol" "shadowsocks")
                   (cons "settings"
                         (list :obj
                               (cons "servers"
                                     (list :arr
                                           (list :obj
                                                 (cons "address"  (proxy-config-host     cfg))
                                                 (cons "port"     (proxy-config-port     cfg))
                                                 (cons "method"   (proxy-config-method   cfg))
                                                 (cons "password" (proxy-config-password cfg)))))))
                   (cons "tag" "proxy"))))))
    (list :obj
          (cons "log"
                (list :obj (cons "loglevel" "warning")))
          (cons "inbounds"
                (list :arr
                      (list :obj
                            (cons "listen"   "127.0.0.1")
                            (cons "port"     socks-port)
                            (cons "protocol" "socks")
                            (cons "settings" (list :obj (cons "udp" :false))))))
          (cons "outbounds"
                (list :arr outbound)))))

  ;;; ---------------------------------------------------------------------
  ;;; Process helpers
  ;;; ---------------------------------------------------------------------

(defun run-and-capture (argv &key input timeout)
  "Run ARGV, return (values exit-code stdout stderr).
Kills after TIMEOUT seconds and always closes process streams."
  (let* ((proc (sb-ext:run-program (first argv) (rest argv)
                                   :input input
                                   :output :stream
                                   :error :stream
                                   :wait nil
                                   :search t))
         (out-stream (sb-ext:process-output proc))
         (err-stream (sb-ext:process-error proc)))
    (unwind-protect
         (progn
           (when timeout
             (let ((deadline (+ (get-internal-real-time)
                                (* timeout internal-time-units-per-second))))
               (loop while (and (sb-ext:process-alive-p proc)
                                (< (get-internal-real-time) deadline))
                     do (sleep 0.1))
               (when (sb-ext:process-alive-p proc)
                 (sb-ext:process-kill proc 9 :pid)
                 (sleep 0.2))))

           (sb-ext:process-wait proc)

           (flet ((slurp (stream)
                    (when stream
                      (with-output-to-string (result)
                        (loop for line = (read-line stream nil nil)
                              while line
                              do (write-line line result))))))
             (values (sb-ext:process-exit-code proc)
                     (slurp out-stream)
                     (slurp err-stream))))

      ;; Важно: освобождаем pipe от stdout/stderr curl.
      (ignore-errors (when out-stream (close out-stream)))
      (ignore-errors (when err-stream (close err-stream)))

      ;; Страховка на случай исключения посреди теста.
      (ignore-errors
       (when (sb-ext:process-alive-p proc)
         (sb-ext:process-kill proc 9 :pid)))
      (ignore-errors (sb-ext:process-wait proc)))))  

  ;;; ---------------------------------------------------------------------
  ;;; Speed test via SOCKS5
  ;;; ---------------------------------------------------------------------

(defun speedtest-via-socks-once (socks-port &key (url (first *test-urls*)) (timeout *download-timeout*))
  "Download URL through local SOCKS5 on SOCKS-PORT; return (values ok seconds bytes mbps err)."
  (format t "[speedtest] Starting download from ~A through SOCKS5 port ~A~%" url socks-port)
  (multiple-value-bind (code out err)
      (run-and-capture (list "curl"
                             "-sS" "-L"
                             "--http1.1"
                             "-o" "/dev/null"
                             "--socks5-hostname" (format nil "127.0.0.1:~a" socks-port)
                             "--max-time" (princ-to-string timeout)
                             "-w" "%{http_code} %{size_download} %{time_total}"
                             url)
                       :timeout (+ timeout 5))
    
    (if (and (eql code 0) out)
        (let* ((trimmed (string-trim '(#\Space #\Newline) out))
               ;; curl sometimes prepends progress; the -w fields are always last
               (parts   (last (str-split trimmed #\Space) 3)))
          (if (= (length parts) 3)
              (let* ((http-code (first parts))
                     (bytes     (parse-integer (second parts) :junk-allowed t))
                     (seconds   (let ((*read-default-float-format* 'double-float))
                                  (ignore-errors (read-from-string (third parts))))))
                (if (and (string= http-code "200") bytes (> bytes 0) seconds (> seconds 0))
                    (values t seconds bytes
                            (/ (* bytes 8.0d0) seconds 1000000.0d0)
                            nil)
                    (values nil nil nil nil
                            (format nil "http=~a bytes=~a secs=~a" http-code bytes seconds))))
              (values nil nil nil nil (format nil "unexpected curl output: ~s" out))))
        (values nil nil nil nil
                (format nil "curl exit=~a~@[; ~a~]"
                        code
                        (and err
                             (> (length (string-trim '(#\Space #\Newline) err)) 0)
                             (string-trim '(#\Space #\Newline) err)))))))
(defun speedtest-via-socks
    (socks-port &key
                  (urls *test-urls*)
                  (timeout *download-timeout*))
  "Проверяет основной URL; при HTTP 429 переключается на следующий URL."
  (labels ((attempt (remaining-urls)
             (let ((url (first remaining-urls)))
               (multiple-value-bind (ok seconds bytes mbps err)
                   (speedtest-via-socks-once socks-port
                                             :url url
                                             :timeout timeout)
                 (cond
                   (ok
                    (values ok seconds bytes mbps err))

                   ((and err
                         (search "http=429" err)
                         (rest remaining-urls))
                    (format t
                            "[speedtest] HTTP 429; switching to ~A~%"
                            (second remaining-urls))
                    (force-output)
                    (attempt (rest remaining-urls)))

                   ;; Сетевые/TLS-обрывы конкретного хоста (не значит, что прокси мёртв):
                   ;; curl exit=35 SSL_ERROR_SYSCALL, 52 empty reply, 56 recv failure,
                   ;; 7 couldn't connect, 28 timeout — пробуем следующий тестовый URL.
                   ((and err
                         (or (search "curl exit=35" err)
                             (search "curl exit=52" err)
                             (search "curl exit=56" err)
                             (search "curl exit=7"  err)
                             (search "curl exit=28" err))
                         (rest remaining-urls))
                    (format t
                            "[speedtest] ~A; switching to ~A~%"
                            (subseq err 0 (min 60 (length err)))
                            (second remaining-urls))
                    (force-output)
                    (attempt (rest remaining-urls)))

                   (t
                    (values ok seconds bytes mbps err)))))))
    (attempt urls)))

  ;;; ---------------------------------------------------------------------
  ;;; TCP pre-filter — thread-based so blocking connect can be timed out
  ;;; ---------------------------------------------------------------------

(defun tcp-alive-p (host port &optional (timeout 4))
  "Return T if TCP connect to HOST:PORT succeeds within TIMEOUT seconds."
  (let (result done)
    (let ((th (sb-thread:make-thread
               (lambda ()
                 (setf result
                       (handler-case
                           (let ((sock (make-instance 'sb-bsd-sockets:inet-socket
                                                      :type :stream :protocol :tcp)))
                             (unwind-protect
                                  (progn
                                    (sb-bsd-sockets:socket-connect
                                     sock
                                     (car (sb-bsd-sockets:host-ent-addresses
                                           (sb-bsd-sockets:get-host-by-name host)))
                                     port)
                                    t)
                               (ignore-errors (sb-bsd-sockets:socket-close sock))))
                         (error () nil)))
                 (setf done t))
               :name "tcp-probe")))
      (let ((deadline (+ (get-internal-real-time)
                         (* timeout internal-time-units-per-second))))
        (loop until (or done (>= (get-internal-real-time) deadline))
              do (sleep 0.05)))
      (unless done
        (ignore-errors (sb-thread:terminate-thread th))))
    result))

  ;;; ---------------------------------------------------------------------
  ;;; Test one URI end-to-end
  ;;; ---------------------------------------------------------------------

(defun test-one-config (uri &key (test-urls *test-urls*) (dl-timeout *download-timeout*)
                                 (verbose t) (index nil) (total nil))
  (let* ((prefix (if (and index total)
                     (format nil "[~a/~a] " index total)
                     ""))
         (cfg (ignore-errors (parse-config-uri uri))))
    (unless cfg
      (when verbose
        (format t "~aSKIP  cannot parse: ~a~%" prefix uri)
        (force-output))
      (return-from test-one-config (list :uri uri :status :unparseable)))
    
    (when verbose
      (format t "~aTCP   ~a (~a:~a) ..." prefix
              (proxy-config-tag cfg) (proxy-config-host cfg) (proxy-config-port cfg))
      (force-output))
    
    (unless (tcp-alive-p (proxy-config-host cfg) (proxy-config-port cfg))
      (when verbose (format t " DEAD~%") (force-output))
      (return-from test-one-config (list :uri uri :status :tcp-dead :cfg cfg)))
    
    (when verbose (format t " OK~%") (force-output))
    
    (let* ((socks-port  (free-local-port))
           (xray-config (build-xray-config cfg socks-port))
           (config-path (format nil "/tmp/xray-cfg-~a.json" socks-port)))
      (with-open-file (f config-path :direction :output :if-exists :supersede)
        (write-string (json-to-string xray-config) f))
      (when verbose
        (format t "~axray  ~a ... " prefix (proxy-config-tag cfg))
        (force-output))
      (let ((proc (sb-ext:run-program *xray-path*
                                      (list "run" "-c" config-path)
                                      :output nil :error nil :wait nil :search t)))
        (unwind-protect
             (progn
               (sleep 0.8)
               (if (not (sb-ext:process-alive-p proc))
                   (progn
                     (when verbose (format t "xray failed to start~%") (force-output))
                     (list :uri uri :status :xray-failed-to-start :cfg cfg))
                   (progn
                     (when verbose (format t "dl ... ") (force-output))
                     (multiple-value-bind (ok seconds bytes mbps err)
                         (speedtest-via-socks socks-port :urls test-urls :timeout dl-timeout)
                       (if ok
                           (progn
                             (when verbose
                               (format t "~,2fMbps~%" mbps)
                               (format t "      >>> ~a~%" uri)
                               (force-output))
                             (list :uri uri :status :ok :cfg cfg
                                   :seconds seconds :bytes bytes :mbps mbps))
                           (progn
                             (when verbose
                               (format t "FAIL (~a)~%" err)
                               (force-output))
                             (list :uri uri :status :proxy-dead :cfg cfg :error err)))))))
          (when (sb-ext:process-alive-p proc)
            (sb-ext:process-kill proc 9 :pid))
          (sb-ext:process-wait proc)
          (ignore-errors (delete-file config-path)))))))

  ;;; ---------------------------------------------------------------------
  ;;; Parallel map with bounded worker count
  ;;; ---------------------------------------------------------------------

(defun pmap-bounded (fn items &key (max-workers 1))
  "Apply FN to each item with up to MAX-WORKERS threads. Results in original order."
  (if (<= max-workers 1)
      (mapcar fn items)
      (let* ((n       (length items))
             (results (make-array n :initial-element :pending))
             (sem     (sb-thread:make-semaphore :count max-workers)))
        (let ((threads
                (loop for item in items
                      for i from 0
                      do (sb-thread:wait-on-semaphore sem)
                      collect (let ((item item) (i i))
                                (sb-thread:make-thread
                                 (lambda ()
                                   (unwind-protect
                                        (setf (aref results i) (funcall fn item))
                                     (sb-thread:signal-semaphore sem)))
                                 :name (format nil "speedtest-~a" i))))))
          (dolist (th threads) (ignore-errors (sb-thread:join-thread th))))
        (coerce results 'list))))

  ;;; ---------------------------------------------------------------------
  ;;; Report
  ;;; ---------------------------------------------------------------------

(defun format-result (r)
  (let ((cfg (getf r :cfg)))
    (flet ((tag () (if cfg (proxy-config-tag cfg) "?")))
      (case (getf r :status)
        (:ok
         (format nil "OK    ~8,2f Mbps  (~4,1fs  ~8d B)  ~a"
                 (getf r :mbps) (getf r :seconds) (getf r :bytes) (tag)))
        (:tcp-dead
         (format nil "DEAD  tcp unreachable              ~a" (tag)))
        (:xray-failed-to-start
         (format nil "FAIL  xray crashed                 ~a" (tag)))
        (:proxy-dead
         (format nil "FAIL  no traffic (~30a)  ~a" (getf r :error) (tag)))
        (:unparseable
         (format nil "SKIP  bad URI                      ~a" (getf r :uri)))
        (t
         (format nil "???   ~s" r))))))

(defun write-sorted-configs (sorted-results out-path kind)
  "Записывает OK-результаты вида KIND (:vless | :shadowsocks) из уже
     отсортированных SORTED-RESULTS в OUT-PATH, в том же формате что и консоль."
  (with-open-file (f (merge-pathnames out-path *script-dir*)
                     :direction :output
                     :if-exists :supersede
                     :if-does-not-exist :create)
    (dolist (r sorted-results)
      (when (and (eq (getf r :status) :ok)
                 (eq (proxy-config-kind (getf r :cfg)) kind))
        (format f "  ~a~%~a~%~%" (format-result r) (getf r :uri))))))

  ;;; ---------------------------------------------------------------------
  ;;; Main orchestrator
  ;;; ---------------------------------------------------------------------

(defun speedtest-configs (uris &key (test-urls *test-urls*) (dl-timeout *download-timeout*)
                                    (jobs 1) (verbose t) (name "out"))
  "Test every URI. Print ranked report. Returns result list."
  (format t "~%speedtest-configs: ~a URI~:p, ~a worker~:p, ~as timeout/each~%~%"
          (length uris) jobs dl-timeout)
  (force-output)
  (let* ((total   (length uris))
         (counter (cons 0 (sb-thread:make-mutex)))
         (results (pmap-bounded
                   (lambda (uri)
                     (let ((idx (sb-thread:with-mutex ((cdr counter))
                                  (prog1 (car counter) (incf (car counter))))))
                       (test-one-config uri
                                        :test-urls   test-urls
                                        :dl-timeout dl-timeout
                                        :verbose    verbose
                                        :index      (1+ idx)
                                        :total      total)))
                   uris
                   :max-workers jobs)))
    (let ((sorted (sort (copy-list results) #'>
                        :key (lambda (r) (or (getf r :mbps) -1)))))
      (write-sorted-configs sorted (format nil "vless-~a.txt" name) :vless)
      (write-sorted-configs sorted (format nil "ss-~a.txt"    name) :shadowsocks)
      (format t "  saved: vless-~a.txt, ss-~a.txt~%" name name)
      (format t "────────────────────────────────────────────────────────~%~%"))
    results))

  ;;; ---------------------------------------------------------------------
  ;;; I/O helpers
  ;;; ---------------------------------------------------------------------

(defun read-uris-from-file (path)
  (with-open-file (f path)
    (loop for line = (read-line f nil nil)
          while line
          for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
          when (and (> (length trimmed) 0)
                    (not (char= (char trimmed 0) #\;)))  ; ; = comment
          collect trimmed)))

(defun read-uris-from-stdin ()
  (loop for line = (read-line *standard-input* nil nil)
        while line
        for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
        when (and (> (length trimmed) 0)
                  (not (char= (char trimmed 0) #\;)))
        collect trimmed))

(defun read-uris-from-url (url)
  "Fetch URL via curl and return list of trimmed, non-empty, non-comment lines."
  (multiple-value-bind (code out err) (run-and-capture (list "curl" "-sS" "-L" url) :timeout 20)
    (unless (and (eql code 0) out)
      (error "read-uris-from-url: curl failed (exit=~a): ~a" code err))
    (loop for line in (str-split out #\Newline)
          for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
          when (and (> (length trimmed) 0)
                    (not (char= (char trimmed 0) #\;)))
          collect trimmed)))

  ;;; ---------------------------------------------------------------------
  ;;; Argument parser & entry point
  ;;; ---------------------------------------------------------------------

(defun parse-argv ()
  "Parse *posix-argv* rest. Returns (values jobs remaining-args)."
  (let ((all  (rest sb-ext:*posix-argv*))
        (jobs 1)
        rest)
    (loop with skip = nil
          for a in all
          do (cond
               (skip        (setf skip nil))
               ((string= a "-j")
                (let ((nxt (cadr (member a all :test #'string=))))
                  (when nxt (setf jobs (or (parse-integer nxt :junk-allowed t) 1)))
                  (setf skip t)))
               (t (push a rest))))
    (values jobs (nreverse rest))))


(defun read-lines (path)
  (with-open-file (f path :external-format :utf-8)
    (loop for line = (read-line f nil nil)
          while line
          when (> (length (string-trim '(#\Space #\Tab) line)) 0)
          collect line))) 
