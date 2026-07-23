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

(defun json-skip-ws (str i)
  (loop while (and (< i (length str))
                    (member (char str i) '(#\Space #\Tab #\Newline #\Return)))
        do (incf i))
  i)

(defun json-parse-string (str i)
  "STR[i] is the opening quote. Returns (values decoded-string index-after-closing-quote)."
  (incf i)
  (let ((out (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
    (loop
      (let ((ch (char str i)))
        (cond
          ((char= ch #\") (return (values (coerce out 'simple-string) (1+ i))))
          ((char= ch #\\)
           (incf i)
           (let ((esc (char str i)))
             (vector-push-extend
              (case esc
                (#\n #\Newline) (#\t #\Tab) (#\r #\Return)
                (#\" #\") (#\\ #\\) (#\/ #\/)
                (#\u (let ((code (parse-integer str :start (1+ i) :end (+ i 5) :radix 16)))
                       (incf i 4)
                       (code-char code)))
                (t esc))
              out)
             (incf i)))
          (t (vector-push-extend ch out) (incf i)))))))

(defun json-parse-value (str i)
  "Minimal recursive-descent JSON reader, sufficient for the flat vmess
   payload object (and any nesting someone throws at it). Returns
   (values lisp-value index-after-value); lisp-value shapes match json-write:
   (:obj (k . v)...) | (:arr v...) | string | number | t | :false | :null."
  (setf i (json-skip-ws str i))
  (let ((ch (char str i)))
    (cond
      ((char= ch #\") (json-parse-string str i))
      ((char= ch #\{)
       (incf i)
       (setf i (json-skip-ws str i))
       (let (pairs)
         (when (char= (char str i) #\})
           (return-from json-parse-value (values (cons :obj nil) (1+ i))))
         (loop
           (setf i (json-skip-ws str i))
           (multiple-value-bind (key ni) (json-parse-string str i)
             (setf i (json-skip-ws str ni))
             (assert (char= (char str i) #\:))
             (incf i)
             (multiple-value-bind (val ni2) (json-parse-value str i)
               (push (cons key val) pairs)
               (setf i (json-skip-ws str ni2))))
           (cond
             ((char= (char str i) #\,) (incf i))
             ((char= (char str i) #\}) (return (values (cons :obj (nreverse pairs)) (1+ i))))
             (t (error "json: expected , or } at ~a" i))))))
      ((char= ch #\[)
       (incf i)
       (setf i (json-skip-ws str i))
       (let (items)
         (when (char= (char str i) #\])
           (return-from json-parse-value (values (cons :arr nil) (1+ i))))
         (loop
           (multiple-value-bind (val ni) (json-parse-value str i)
             (push val items)
             (setf i (json-skip-ws str ni)))
           (cond
             ((char= (char str i) #\,) (incf i) (setf i (json-skip-ws str i)))
             ((char= (char str i) #\]) (return (values (cons :arr (nreverse items)) (1+ i))))
             (t (error "json: expected , or ] at ~a" i))))))
      ((and (<= (+ i 4) (length str)) (string= str "true" :start1 i :end1 (+ i 4)))
       (values t (+ i 4)))
      ((and (<= (+ i 5) (length str)) (string= str "false" :start1 i :end1 (+ i 5)))
       (values :false (+ i 5)))
      ((and (<= (+ i 4) (length str)) (string= str "null" :start1 i :end1 (+ i 4)))
       (values :null (+ i 4)))
      (t
       (let ((start i))
         (loop while (and (< i (length str)) (find (char str i) "+-0123456789.eE"))
               do (incf i))
         (values (let ((*read-default-float-format* 'double-float))
                   (read-from-string (subseq str start i)))
                 i))))))

(defun json-parse (str)
  "Parse STR into (:obj (k . v)...) / (:arr v...) / string / number / t / :false / :null."
  (values (json-parse-value str 0)))

(defun json-as-string (v)
  "Coerce a JSON scalar to a string; vmess fields are inconsistently typed
   across generators (aid/port show up as either strings or numbers)."
  (cond
    ((stringp v) v)
    ((numberp v) (princ-to-string v))
    ((eq v t) "true")
    ((eq v :false) "false")
    (t "")))

(defun json-obj-get (obj key &optional (default ""))
  "OBJ is (:obj (k . v)...) as returned by json-parse. Look up KEY (a string)."
  (let ((pair (assoc key (cdr obj) :test #'string=)))
    (if pair (json-as-string (cdr pair)) default)))

(defstruct proxy-config
  kind
  tag
  uuid
  method
  password
  host port
  raw
  extra)

(defun strip-fragment (uri)
  "Return (values uri-without-fragment fragment-or-nil)."
  (multiple-value-bind (before after) (split-once uri #\#)
    (values before (and after (url-decode after)))))

(defun parse-simple-uri (uri scheme kind)
  "Shared parser for the '<scheme>://<credential>@<host>:<port>?<query>#<name>'
   shape used by both vless (credential = uuid) and trojan (credential = password).
   Returns (values credential host port tag extra-alist)."
  (multiple-value-bind (body name) (strip-fragment uri)
    (let* ((body   (subseq body (length scheme)))
           (at-pos (position #\@ body)))
      (unless at-pos (error "~a: no @ in ~a" kind uri))
      (let ((credential (subseq body 0 at-pos))
            (rest       (subseq body (1+ at-pos))))
        (multiple-value-bind (hostport query) (split-once rest #\?)
          (multiple-value-bind (host port-str) (split-last hostport #\:)
            (unless port-str (error "~a: no port in ~a" kind uri))
            (values credential host
                    (or (parse-integer port-str :junk-allowed t)
                        (error "~a: bad port ~s" kind port-str))
                    (or name host)
                    (parse-query query))))))))

(defun parse-vless (uri)
  (multiple-value-bind (uuid host port tag extra) (parse-simple-uri uri "vless://" :vless)
    (make-proxy-config
     :kind :vless :tag tag :uuid uuid :host host :port port :raw uri :extra extra)))

(defun parse-trojan (uri)
  (multiple-value-bind (password host port tag extra) (parse-simple-uri uri "trojan://" :trojan)
    (make-proxy-config
     :kind :trojan :tag tag :password password :host host :port port :raw uri
     ;; Trojan is TLS-by-default (that's the whole point of the protocol);
     ;; only fall back to it if the query string didn't already say otherwise.
     :extra (if (assoc "security" extra :test #'string=)
                extra
                (cons (cons "security" "tls") extra)))))

(defun parse-vmess (uri)
  "VMess links carry no query string at all: everything (including
   transport/TLS settings) is base64-encoded JSON. We normalize the JSON
   field names to the same keys vless/trojan's query-string extras use
   (path, host, sni, fp, security, type, serviceName) so the existing
   singbox-tls-fields / singbox-transport-fields builders can be reused as-is."
  (multiple-value-bind (body _frag) (strip-fragment (subseq uri (length "vmess://")))
    (declare (ignore _frag))
    (let* ((obj      (json-parse (b64-decode body)))
           (host     (json-obj-get obj "add"))
           (port-str (json-obj-get obj "port"))
           (net      (json-obj-get obj "net" "tcp"))
           (tls      (json-obj-get obj "tls"))
           (path     (json-obj-get obj "path" "/"))
           (host-hdr (json-obj-get obj "host"))
           (sni      (json-obj-get obj "sni" host-hdr))
           (fp       (json-obj-get obj "fp" "chrome"))
           (scy      (json-obj-get obj "scy" "auto")))
      (unless (and (consp obj) (eq (car obj) :obj))
        (error "vmess: payload is not a JSON object"))
      (make-proxy-config
       :kind   :vmess
       :tag    (let ((ps (json-obj-get obj "ps"))) (if (plusp (length ps)) ps host))
       :uuid   (json-obj-get obj "id")
       :method (if (plusp (length scy)) scy "auto")
       :host   host
       :port   (or (parse-integer port-str :junk-allowed t)
                   (error "vmess: bad port ~s" port-str))
       :raw    uri
       :extra  (append
                (list (cons "type" net)
                      (cons "security" (if (string= tls "tls") "tls" "none"))
                      (cons "path" path)
                      (cons "fp" fp)
                      ;; grpc vmess links conventionally stash the service
                      ;; name in "path" rather than a dedicated field.
                      (cons "serviceName" path)
                      (cons "alterId" (json-obj-get obj "aid" "0")))
                ;; Only include host/sni when actually present, so downstream
                ;; consumers' own fallback defaults (e.g. host->server address)
                ;; still kick in instead of being shadowed by "".
                (when (plusp (length host-hdr)) (list (cons "host" host-hdr)))
                (when (plusp (length sni))      (list (cons "sni"  sni))))))))

(defun finish-ss-config (name method password hp uri)
  "Shared tail for both Shadowsocks URI forms once METHOD/PASSWORD/HP
   (host:port) have been pulled out — only how they got there differs
   between the modern and legacy forms."
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
     :extra    nil)))

(defun parse-shadowsocks (uri)
  (multiple-value-bind (body name) (strip-fragment uri)
    (let ((body (subseq body (length "ss://"))))
      (multiple-value-bind (userinfo hostport) (split-once body #\@)
        (if hostport
            ;; Modern Shadowsocks URI form.
            (let ((decoded (if (position #\: userinfo)
                               userinfo
                               (b64-decode userinfo))))
              (multiple-value-bind (method password) (split-once decoded #\:)
                (multiple-value-bind (hp _q) (split-once hostport #\?)
                  (declare (ignore _q))
                  (finish-ss-config name method password hp uri))))
            ;; Legacy base64-encoded URI form.
            (let ((decoded (b64-decode body)))
              (multiple-value-bind (userinfo hp) (split-once decoded #\@)
                (multiple-value-bind (method password) (split-once userinfo #\:)
                  (finish-ss-config name method password hp uri)))))))))

(defun parse-hysteria2 (uri)
  "hysteria2://<auth>@<host>:<port>?<query>#<name>. AUTH is an opaque
   password (sometimes a UUID, sometimes base64-ish with +/= in it) — no
   different in shape from trojan's, so parse-simple-uri handles it as-is,
   including the '<port>/' form some generators emit before the '?'."
  (multiple-value-bind (password host port tag extra)
      (parse-simple-uri uri "hysteria2://" :hysteria2)
    (make-proxy-config
     :kind :hysteria2 :tag tag :password password :host host :port port
     :raw uri :extra extra)))

(defun parse-config-uri (uri)
  (let ((uri (string-trim '(#\Space #\Newline #\Return #\Tab) uri)))
    (cond
      ((and (>= (length uri) 8) (string= uri "vless://" :end1 8))
       (parse-vless uri))
      ((and (>= (length uri) 8) (string= uri "vmess://" :end1 8))
       (parse-vmess uri))
      ((and (>= (length uri) 9) (string= uri "trojan://" :end1 9))
       (parse-trojan uri))
      ((and (>= (length uri) 5) (string= uri "ss://" :end1 5))
       (parse-shadowsocks uri))
      ((and (>= (length uri) 12) (string= uri "hysteria2://" :end1 12))
       (parse-hysteria2 uri))
      (t nil))))

(defun singbox-tls-fields (cfg extra security)
  "Returns an alist of (\"tls\" . <obj>) or nil if there's no TLS at all."
  (cond
    ((string= security "reality")
     (list
      (cons "tls"
            (list :obj
                  (cons "enabled" t)
                  (cons "server_name" (qval extra "sni" ""))
                  (cons "utls" (list :obj
                                     (cons "enabled" t)
                                     (cons "fingerprint" (qval extra "fp" "chrome"))))
                  (cons "reality" (list :obj
                                        (cons "enabled" t)
                                        (cons "public_key" (qval extra "pbk" ""))
                                        (cons "short_id" (qval extra "sid" ""))))))))
    ((string= security "tls")
     (let ((insecure (or (string= (qval extra "allowInsecure" "0") "1")
                         (string= (qval extra "insecure" "0") "1"))))
       (list
        (cons "tls"
              (list :obj
                    (cons "enabled" t)
                    (cons "server_name" (qval extra "sni" (proxy-config-host cfg)))
                    (cons "insecure" (if insecure t :false))
                    (cons "utls" (list :obj
                                       (cons "enabled" t)
                                       (cons "fingerprint" (qval extra "fp" "chrome")))))))))
    (t nil)))

(defun singbox-transport-fields (extra network default-host)
  "Returns an alist of (\"transport\" . <obj>) or nil for plain tcp.
   DEFAULT-HOST is used as the ws Host header when the URI has no explicit
   host= param — falls back to sni, then the server address, mirroring what
   other clients (v2rayN/Xray) do for CDN-fronted configs."
  (cond
    ((string= network "ws")
     (list (cons "transport"
                 (list :obj
                       (cons "type" "ws")
                       (cons "path" (qval extra "path" "/"))
                       (cons "headers" (list :obj (cons "Host" (qval extra "host" default-host))))))))
    ((string= network "grpc")
     (list (cons "transport"
                 (list :obj
                       (cons "type" "grpc")
                       (cons "service_name" (qval extra "serviceName" ""))))))
    (t nil)))

(defun ws-fallback-host (cfg extra)
  "Default Host header for ws transport when the URI has no explicit
   host= param: fall back to sni, then the server address itself."
  (qval extra "sni" (proxy-config-host cfg)))

(defun vless-outbound-singbox (cfg)
  (let* ((extra    (proxy-config-extra cfg))
         (network  (qval extra "type" "tcp"))
         (security (qval extra "security" "none"))
         (flow     (qval extra "flow" "")))
    (cons :obj
          (append
           (list (cons "type" "vless")
                 (cons "tag" "proxy")
                 (cons "server" (proxy-config-host cfg))
                 (cons "server_port" (proxy-config-port cfg))
                 (cons "uuid" (proxy-config-uuid cfg)))
           ;; Omit empty flow: sing-box distinguishes it from an absent field.
           (when (plusp (length flow)) (list (cons "flow" flow)))
           (singbox-tls-fields cfg extra security)
           (singbox-transport-fields extra network (ws-fallback-host cfg extra))))))

(defun trojan-outbound-singbox (cfg)
  (let* ((extra    (proxy-config-extra cfg))
         (network  (qval extra "type" "tcp"))
         (security (qval extra "security" "tls")))
    (cons :obj
          (append
           (list (cons "type" "trojan")
                 (cons "tag" "proxy")
                 (cons "server" (proxy-config-host cfg))
                 (cons "server_port" (proxy-config-port cfg))
                 (cons "password" (proxy-config-password cfg)))
           (singbox-tls-fields cfg extra security)
           (singbox-transport-fields extra network (ws-fallback-host cfg extra))))))

(defun vmess-outbound-singbox (cfg)
  (let* ((extra       (proxy-config-extra cfg))
         (network     (qval extra "type" "tcp"))
         (tls-status  (qval extra "security" "none"))
         (alter-id    (or (parse-integer (qval extra "alterId" "0") :junk-allowed t) 0)))
    (cons :obj
          (append
           (list (cons "type" "vmess")
                 (cons "tag" "proxy")
                 (cons "server" (proxy-config-host cfg))
                 (cons "server_port" (proxy-config-port cfg))
                 (cons "uuid" (proxy-config-uuid cfg))
                 ;; sing-box's vmess "security" is the AEAD cipher (auto/aes-128-gcm/...),
                 ;; not to be confused with tls-status (TLS on/off) below.
                 (cons "security" (proxy-config-method cfg))
                 (cons "alter_id" alter-id))
           (singbox-tls-fields cfg extra tls-status)
           (singbox-transport-fields extra network (ws-fallback-host cfg extra))))))

(defun shadowsocks-outbound-singbox (cfg)
  (list :obj
        (cons "type" "shadowsocks")
        (cons "tag" "proxy")
        (cons "server" (proxy-config-host cfg))
        (cons "server_port" (proxy-config-port cfg))
        (cons "method" (proxy-config-method cfg))
        (cons "password" (proxy-config-password cfg))))

(defun hysteria2-outbound-singbox (cfg)
  "Hysteria2 is TLS-by-definition (no security= toggle like vless/trojan),
   so tls is always emitted. obfs is only emitted when the URI actually
   specifies one — sing-box treats a present-but-empty obfs object as an
   error, unlike the other protocols' omit-when-empty transport fields."
  (let* ((extra    (proxy-config-extra cfg))
         (insecure (or (string= (qval extra "insecure" "0") "1")
                       (string= (qval extra "allowInsecure" "0") "1")))
         (obfs     (qval extra "obfs" ""))
         (obfs-pw  (qval extra "obfs-password" "")))
    (cons :obj
          (append
           (list (cons "type" "hysteria2")
                 (cons "tag" "proxy")
                 (cons "server" (proxy-config-host cfg))
                 (cons "server_port" (proxy-config-port cfg))
                 (cons "password" (proxy-config-password cfg)))
           (when (plusp (length obfs))
             (list (cons "obfs" (list :obj
                                       (cons "type" obfs)
                                       (cons "password" obfs-pw)))))
           (list (cons "tls"
                       (list :obj
                             (cons "enabled" t)
                             (cons "server_name" (qval extra "sni" (proxy-config-host cfg)))
                             (cons "insecure" (if insecure t :false)))))))))

(defun proxy-outbound-singbox (cfg)
  (ecase (proxy-config-kind cfg)
    (:vless       (vless-outbound-singbox cfg))
    (:trojan      (trojan-outbound-singbox cfg))
    (:vmess       (vmess-outbound-singbox cfg))
    (:shadowsocks (shadowsocks-outbound-singbox cfg))
    (:hysteria2   (hysteria2-outbound-singbox cfg))))

;;; Default SOCKS-PORT (1080) must stay synchronized with *socks-port*
;;; for dog.lisp's own use. Callers testing multiple configs in parallel
;;; (e.g. the speedtest script) pass their own free port instead.

(defun build-singbox-config (cfg &key (socks-port 1080))
  (list :obj
        (cons "log" (list :obj (cons "level" "warn")))
        (cons "dns"
              (list :obj
                    (cons "servers"
                          (list :arr
                                (list :obj
                                      (cons "tag" "proxy-dns")
                                      (cons "type" "https")
                                      (cons "server" "1.1.1.1")
                                      (cons "detour" "proxy"))))))
        (cons "inbounds"
              (list :arr
                    (list :obj
                          (cons "type" "mixed")
                          (cons "listen" "127.0.0.1")
                          (cons "listen_port" socks-port))))
        (cons "outbounds" (list :arr (proxy-outbound-singbox cfg)))))


(defun read-uri-lines (txt-path)
  "One vless://, vmess://, trojan://, ss://, or hysteria2:// URI per line. Blank lines
   and lines starting with # are ignored, so you can comment things out
   or leave notes."
  (with-open-file (in txt-path :direction :input)
    (loop for line = (read-line in nil nil)
          while line
          for trimmed = (string-trim '(#\Space #\Tab #\Return) line)
          unless (or (zerop (length trimmed)) (char= (char trimmed 0) #\#))
          collect trimmed)))

(defun load-server-pool (txt-path config-dir)
  "Parse every URI in TXT-PATH, write each as its own complete sing-box
   config file under CONFIG-DIR, and return a list of plists shaped
   exactly like dog.lisp's *config-pool* entries: (:label :path :ip :port).

   One bad line doesn't abort the whole load — it's reported and skipped,
   since a single malformed entry in someone's pasted server list
   shouldn't cost you every other config in the file."
  (ensure-directories-exist (merge-pathnames "./" config-dir))
  (loop for uri in (read-uri-lines txt-path)
        for i from 1
        for cfg = (handler-case (parse-config-uri uri)
                    (error (e)
                      (format t "~&[pool] skipping line ~a, failed to parse: ~a~%" i e)
                      nil))
        when cfg
        collect (let* ((path (namestring
                              (merge-pathnames (format nil "server-~2,'0d.json" i)
                                               config-dir))))
                  (with-open-file (out path :direction :output
                                            :if-exists :supersede
                                            :if-does-not-exist :create)
                    (json-write (build-singbox-config cfg) out))
                  (list :label (proxy-config-tag cfg)
                        :path  path
                        :ip    (proxy-config-host cfg)
                        :port  (proxy-config-port cfg)))))