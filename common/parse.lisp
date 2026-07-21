
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

(defun write-utf8-octets (octets stream)
  (when (plusp (length octets))
    (write-string
     (sb-ext:octets-to-string
      (coerce octets '(simple-array (unsigned-byte 8) (*)))
      :external-format :utf-8)
     stream)
    (setf (fill-pointer octets) 0)))

(defun url-decode (str)
  "Decode percent-escaped UTF-8 bytes, preserving literal characters."
  (with-output-to-string (out)
    (let ((pending
            (make-array 0
                        :element-type '(unsigned-byte 8)
                        :adjustable t
                        :fill-pointer 0)))
      (loop with i = 0
            while (< i (length str))
            for ch = (char str i)
            if (and (char= ch #\%)
                    (< (+ i 2) (length str))
                    (digit-char-p (char str (1+ i)) 16)
                    (digit-char-p (char str (+ i 2)) 16))
            do (vector-push-extend
                (parse-integer str :start (1+ i) :end (+ i 3) :radix 16)
                pending)
               (incf i 3)
            else
            do (write-utf8-octets pending out)
               (write-char ch out)
               (incf i)
            finally (write-utf8-octets pending out)))))

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
