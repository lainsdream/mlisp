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
  '("https://speed.cloudflare.com/__down?bytes=10000000" "https://proof.ovh.net/files/10Mb.dat"))
(defparameter *download-timeout* 5)  ; seconds per config
(defparameter *script-dir* (make-pathname :directory (pathname-directory (or *load-truename* *default-pathname-defaults*))))

(defparameter *bypass-interface* nil
  "Controls whether config tests bypass an active system VPN by sourcing
outbound traffic from the physical network interface instead of letting it
follow the OS default route (which a VPN typically hijacks).
  NIL        -- auto-detect the physical interface's IPv4 address (macOS,
                via `networksetup`) the first time it's needed, then cache it.
  \"a.b.c.d\"  -- use this local IPv4 address explicitly (skip auto-detect).
  :none      -- disable bypassing; tests go through whatever route the OS
                picks (i.e. through the VPN if one is active).")

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

  ;;; ---------------------------------------------------------------------
  ;;; De-duplicate config URIs
  ;;; ---------------------------------------------------------------------
  ;;;
  ;;; Subscriptions commonly re-list the same underlying server account
  ;;; under several display names / fingerprints / short-ids (e.g. one
  ;;; VLESS uuid@host:port shown 5x as "0172", "0388", "[OpenRay] ...",
  ;;; etc, differing only in cosmetic query params). Testing each of
  ;;; those separately wastes a full TCP+xray+download+stability cycle
  ;;; per copy for a result that will be near-identical. We dedupe on
  ;;; the actual credential identity, not the raw URI string.

(defun config-identity-key (uri)
  "Key identifying which server account URI authenticates against,
ignoring cosmetic differences (tag, fingerprint, short-id, transport
type, etc). Two URIs with the same key are the same account on the same
server for speedtesting purposes. Returns NIL if URI can't be parsed --
callers should treat unparseable URIs as always-unique (never dedupe
away something we failed to understand)."
  (let ((cfg (ignore-errors (parse-config-uri uri))))
    (when cfg
      (list (proxy-config-kind cfg)
            (string-downcase (proxy-config-host cfg))
            (proxy-config-port cfg)
            (ecase (proxy-config-kind cfg)
              (:vless        (string-downcase (proxy-config-uuid cfg)))
              (:shadowsocks  (cons (proxy-config-method cfg)
                                   (proxy-config-password cfg))))))))

(defun dedupe-uris (uris)
  "Remove URIs that share a CONFIG-IDENTITY-KEY with an earlier URI in
the list, keeping the first occurrence of each and preserving overall
order. URIs that fail to parse are always kept as-is.
Returns (values deduped-uris removed-count)."
  (let ((seen (make-hash-table :test #'equal))
        (removed 0))
    (values
     (loop for uri in uris
           for key = (config-identity-key uri)
           if (and key (gethash key seen))
             do (incf removed)
           else
             collect uri
             and do (when key (setf (gethash key seen) t)))
     removed)))

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

(defun security-stream-fields (cfg extra security)
  (cond
    ((string= security "tls")
     (list
      (cons "security" "tls")
      (cons "tlsSettings"
            (list :obj
                  (cons "serverName"
                        (qval extra "sni" (proxy-config-host cfg)))
                  (cons "allowInsecure" :false)))))

    ((string= security "reality")
     (list
      (cons "security" "reality")
      (cons "realitySettings"
            (list :obj
                  (cons "serverName"  (qval extra "sni" ""))
                  (cons "fingerprint" (qval extra "fp" "chrome"))
                  (cons "publicKey"   (qval extra "pbk" ""))
                  (cons "shortId"     (qval extra "sid" ""))))))

    (t nil)))

(defun transport-stream-fields (cfg extra network)
  (cond
    ((string= network "ws")
     (list
      (cons "wsSettings"
            (list :obj
                  (cons "path" (qval extra "path" "/"))
                  (cons "headers" (list :obj (cons "Host" (qval extra "host" (proxy-config-host cfg)))))))))

    ((string= network "grpc")
     (list
      (cons "grpcSettings"
            (list :obj
                  (cons "serviceName" (qval extra "serviceName" ""))))))

    (t nil)))

(defun stream-settings (cfg)
  (let* ((extra    (proxy-config-extra cfg))
         (network  (qval extra "type" "tcp"))
         (security (qval extra "security" "none")))
    (cons :obj
          (append
           (list (cons "network" network))
           (security-stream-fields cfg extra security)
           (transport-stream-fields cfg extra network)))))

(defun vless-outbound (cfg)
  (let* ((flow (qval (proxy-config-extra cfg) "flow" ""))
         (user
           (list :obj
                 (cons "id"         (proxy-config-uuid cfg))
                 (cons "encryption" "none")
                 (cons "flow"       flow)))
         (server
           (list :obj
                 (cons "address" (proxy-config-host cfg))
                 (cons "port"    (proxy-config-port cfg))
                 (cons "users"   (list :arr user))))
         (settings
           (list :obj
                 (cons "vnext" (list :arr server))))
         (send-through (bypass-local-ip)))
    (append
     (list :obj
           (cons "protocol"       "vless")
           (cons "settings"       settings)
           (cons "streamSettings" (stream-settings cfg))
           (cons "tag"            "proxy"))
     (when send-through (list (cons "sendThrough" send-through))))))

(defun shadowsocks-outbound (cfg)
  (let* ((server
           (list :obj
                 (cons "address"  (proxy-config-host cfg))
                 (cons "port"     (proxy-config-port cfg))
                 (cons "method"   (proxy-config-method cfg))
                 (cons "password" (proxy-config-password cfg))))
         (settings
           (list :obj
                 (cons "servers" (list :arr server))))
         (send-through (bypass-local-ip)))
    (append
     (list :obj
           (cons "protocol" "shadowsocks")
           (cons "settings" settings)
           (cons "tag" "proxy"))
     (when send-through (list (cons "sendThrough" send-through))))))

(defun proxy-outbound (cfg)
  (ecase (proxy-config-kind cfg)
    (:vless       (vless-outbound cfg))
    (:shadowsocks (shadowsocks-outbound cfg))))

(defun socks-inbound (port)
  (list :obj
        (cons "listen" "127.0.0.1")
        (cons "port" port)
        (cons "protocol" "socks")
        (cons "settings"
              (list :obj (cons "udp" :false)))))

(defun build-xray-config (cfg socks-port)
  (list :obj
        (cons "log"
              (list :obj
                    (cons "loglevel" "warning")))
        (cons "inbounds"
              (list :arr (socks-inbound socks-port)))
        (cons "outbounds"
              (list :arr (proxy-outbound cfg)))))

  ;;; ---------------------------------------------------------------------
  ;;; Process helpers
  ;;; ---------------------------------------------------------------------

(defun run-and-capture (argv &key input timeout)
  "Run ARGV, return (values exit-code stdout stderr).
Writes stdout/stderr to temp files to avoid pipe-buffer stalls with large output."
  (let* ((out-file (format nil "/tmp/rac-out-~a.txt" (random 1000000)))
         (err-file (format nil "/tmp/rac-err-~a.txt" (random 1000000)))
         (proc (sb-ext:run-program (first argv) (rest argv)
                                   :input input
                                   :output out-file
                                   :error err-file
                                   :if-output-exists :supersede
                                   :if-error-exists :supersede
                                   :wait nil
                                   :search t)))
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
           (values (sb-ext:process-exit-code proc)
                   (when (probe-file out-file)
                     (with-open-file (s out-file :direction :input)
                       (let ((data (make-string (file-length s))))
                         (read-sequence data s)
                         data)))
                   (when (probe-file err-file)
                     (with-open-file (s err-file :direction :input)
                       (let ((data (make-string (file-length s))))
                         (read-sequence data s)
                         data)))))
      (ignore-errors
       (when (sb-ext:process-alive-p proc)
         (sb-ext:process-kill proc 9 :pid)))
      (ignore-errors (sb-ext:process-wait proc))
      (ignore-errors (delete-file out-file))
      (ignore-errors (delete-file err-file)))))

  ;;; ---------------------------------------------------------------------
  ;;; VPN bypass — source outbound traffic from the physical interface
  ;;; ---------------------------------------------------------------------
  ;;;
  ;;; If a system-wide VPN is up, its virtual interface (utun*) usually grabs
  ;;; the default route, so anything that doesn't explicitly pick a source
  ;;; address -- our raw TCP probe, xray's own outbound dial, and the direct
  ;;; (no-proxy) curl calls -- ends up tunneled through the VPN. That defeats
  ;;; the point of testing configs "as seen from this machine's real network".
  ;;; The fix is to bind/source those connections from the physical
  ;;; interface's local IP explicitly.

(defun detect-physical-local-ip ()
  "Best-effort (macOS): return the IPv4 address of the first active,
non-VPN network service (in `networksetup` service-order, e.g. Wi-Fi /
Ethernet), skipping services with no IP or whose name suggests a VPN.
Returns NIL if nothing usable is found (non-macOS, no networksetup, etc)."
  (ignore-errors
   (multiple-value-bind (code out err)
       (run-and-capture (list "networksetup" "-listnetworkserviceorder") :timeout 3)
     (declare (ignore err))
     (when (eql code 0)
       (let ((services
               (loop for line in (str-split out #\Newline)
                     ;; enabled services look like: "(1) Wi-Fi"
                     when (and (> (length line) 1) (char= (char line 0) #\())
                     collect (let ((close (position #\) line)))
                               (and close (string-trim '(#\Space)
                                                       (subseq line (1+ close))))))))
         (dolist (service services)
           (when (and service
                      (not (search "VPN" service :test #'char-equal))
                      (not (search "tun" service :test #'char-equal)))
             (multiple-value-bind (c2 o2 e2)
                 (run-and-capture (list "networksetup" "-getinfo" service) :timeout 3)
               (declare (ignore e2))
               (when (eql c2 0)
                 (let* ((needle "IP address: ")
                        (pos    (search needle o2)))
                   (when pos
                     (let* ((start (+ pos (length needle)))
                            (end   (or (position #\Newline o2 :start start) (length o2)))
                            (ip    (string-trim '(#\Space #\Return) (subseq o2 start end))))
                       (when (and (> (length ip) 0) (not (string= ip "none")))
                         (return-from detect-physical-local-ip ip))))))))))))))

(defparameter *bypass-local-ip-cache* :unset)

(defparameter *bypass-probe-host* "1.1.1.1"
  "Known-reachable public IP used to sanity-check an auto-detected bypass address.")
(defparameter *bypass-probe-port* 443)

(defun local-ip-routes-out-p (ip &key (timeout 3))
  "T if a TCP connect *sourced from* IP actually reaches the public internet.
This matters because on macOS/BSD, routing is destination-based, not
source-based: simply bind()-ing to the physical interface's address does
NOT override the routing table. Many VPN clients install split-default
routes (0.0.0.0/1 + 128.0.0.0/1) that are MORE specific than a plain
0.0.0.0/0 and still win the lookup regardless of which local address the
socket is bound to -- so a bind-only 'bypass' can silently make every
connection fail instead of actually bypassing anything."
  (let ((local-addr (parse-ipv4-string ip))
        (remote-addr (parse-ipv4-string *bypass-probe-host*))
        result done)
    (when (and local-addr remote-addr)
      (let ((th (sb-thread:make-thread
                 (lambda ()
                   (setf result
                         (ignore-errors
                          (let ((sock (make-instance 'sb-bsd-sockets:inet-socket
                                                     :type :stream :protocol :tcp)))
                            (unwind-protect
                                 (progn
                                   (sb-bsd-sockets:socket-bind sock local-addr 0)
                                   (sb-bsd-sockets:socket-connect sock remote-addr *bypass-probe-port*)
                                   t)
                              (ignore-errors (sb-bsd-sockets:socket-close sock))))))
                   (setf done t))
                 :name "bypass-probe")))
        (let ((deadline (+ (get-internal-real-time)
                           (* timeout internal-time-units-per-second))))
          (loop until (or done (>= (get-internal-real-time) deadline))
                do (sleep 0.05)))
        (unless done (ignore-errors (sb-thread:terminate-thread th)))))
    result))

(defun bypass-local-ip ()
  "Return the local IPv4 address outbound test connections should be sourced
from to bypass an active system VPN, or NIL to use the OS default route.
See *BYPASS-INTERFACE*. Auto-detection is validated (see
LOCAL-IP-ROUTES-OUT-P) before being trusted, and the outcome is cached:
if the candidate address can't actually reach the internet on its own
(typical when a VPN owns the default route via split-default routes),
bypassing is disabled for the session instead of silently breaking every
connection."
  (cond
    ((eq *bypass-interface* :none) nil)
    ((stringp *bypass-interface*) *bypass-interface*)
    (t (if (eq *bypass-local-ip-cache* :unset)
           (setf *bypass-local-ip-cache*
                 (let ((candidate (detect-physical-local-ip)))
                   (cond
                     ((null candidate) nil)
                     ((local-ip-routes-out-p candidate) candidate)
                     (t
                      (format t "~&[bypass] physical interface ~a detected, but traffic sourced ~
from it doesn't reach the internet directly -- your VPN likely owns the default route (possibly ~
via split-default 0.0.0.0/1 + 128.0.0.0/1 routes, common in commercial VPN clients), which a plain ~
socket bind can't override on macOS. Disabling bypass for this session; tests will go through the ~
VPN. To really bypass it you'd need either sudo `route add -host <ip> -interface enX` per target, ~
or a split-tunnel / per-app exclude rule in your VPN client.~%" candidate)
                      (force-output)
                      nil))))
           *bypass-local-ip-cache*))))

(defun parse-ipv4-string (s)
  "Parse \"a.b.c.d\" into a vector #(a b c d), or NIL if S is not a valid
dotted-quad IPv4 literal (also NIL if S is NIL)."
  (when s
    (ignore-errors
     (let ((parts (str-split s #\.)))
       (when (= (length parts) 4)
         (let ((octets (mapcar #'parse-integer parts)))
           (when (every (lambda (o) (<= 0 o 255)) octets)
             (coerce octets 'vector))))))))

  ;;; ---------------------------------------------------------------------
  ;;; Speed test via SOCKS5
  ;;; ---------------------------------------------------------------------

(defun speedtest-via-socks-once (socks-port &key (url (first *test-urls*)) (timeout *download-timeout*))
  "Download URL through local SOCKS5 on SOCKS-PORT.
Return (values ok seconds bytes mbps err partial-p).
If *DOWNLOAD-TIMEOUT* is hit mid-transfer (curl exit=28) but a 200 status
and some bytes already came through, this is treated as a PARTIAL success:
mbps is estimated from what was actually transferred in that window rather
than discarding the config outright. Oversold/rate-limited servers on
public config lists are often reachable and do serve data, just slower
than TIMEOUT allows for a full pull of the test file -- PARTIAL-P lets
callers tell that case apart from a clean full-file download if they care to."
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
    (let* ((trimmed (and out (string-trim '(#\Space #\Newline) out)))
           ;; curl still evaluates -w on a --max-time abort (using whatever
           ;; it collected before bailing), so parts may be present even
           ;; when code /= 0.
           (parts   (and trimmed (last (str-split trimmed #\Space) 3))))
      (flet ((parsed-fields ()
               (when (and parts (= (length parts) 3))
                 (values (first parts)
                         (parse-integer (second parts) :junk-allowed t)
                         (let ((*read-default-float-format* 'double-float))
                           (ignore-errors (read-from-string (third parts))))))))
        (cond
          ;; Clean full-file download.
          ((eql code 0)
           (multiple-value-bind (http-code bytes seconds) (parsed-fields)
             (if (and http-code (string= http-code "200") bytes (> bytes 0) seconds (> seconds 0))
                 (values t seconds bytes (/ (* bytes 8.0d0) seconds 1000000.0d0) nil nil)
                 (values nil nil nil nil
                         (format nil "http=~a bytes=~a secs=~a" http-code bytes seconds)
                         nil))))
          ;; Timed out mid-download: salvage a speed estimate if we actually
          ;; got a 200 and some bytes; otherwise it's just dead/stuck and we
          ;; fall through like before.
          ((eql code 28)
           (multiple-value-bind (http-code bytes seconds) (parsed-fields)
             (if (and http-code (string= http-code "200") bytes (> bytes 0) seconds (> seconds 0))
                 (values t seconds bytes (/ (* bytes 8.0d0) seconds 1000000.0d0) nil t)
                 (values nil nil nil nil
                         (format nil "curl exit=28 (timeout, no usable partial data; http=~a bytes=~a)"
                                 http-code bytes)
                         nil))))
          (t
           (values nil nil nil nil
                   (format nil "curl exit=~a~@[; ~a~]"
                           code
                           (and err
                                (> (length (string-trim '(#\Space #\Newline) err)) 0)
                                (string-trim '(#\Space #\Newline) err)))
                   nil)))))))

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
                                        ;(format t "[speed HTTP 429; switching to ~A~%" (second remaining-urls))
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
                                        ;(format t "[speedtest] ~A; switching to ~A~%" (subseq err 0 (min 60 (length err))) (second remaining-urls))
                    (force-output)
                    (attempt (rest remaining-urls)))

                   (t
                    (values ok seconds bytes mbps err)))))))
    (attempt urls)))

  ;;; ---------------------------------------------------------------------
  ;;; TCP pre-filter — thread-based so blocking connect can be timed out
  ;;; ---------------------------------------------------------------------

(defun tcp-alive-p (host port &optional (timeout 4))
  "Return T if TCP connect to HOST:PORT succeeds within TIMEOUT seconds.
If (BYPASS-LOCAL-IP) resolves to a usable address, the probe socket is bound
to it first, so the connection goes out the physical interface even when a
system VPN has taken over the default route."
  (let (result done)
    (let ((th (sb-thread:make-thread
               (lambda ()
                 (setf result
                       (handler-case
                           (let ((sock      (make-instance 'sb-bsd-sockets:inet-socket
                                                           :type :stream :protocol :tcp))
                                 (local-ip  (parse-ipv4-string (bypass-local-ip))))
                             (unwind-protect
                                  (progn
                                    (when local-ip
                                      ;; Non-fatal: if bind fails (e.g. the
                                      ;; interface's address changed since it
                                      ;; was validated), fall back to an
                                      ;; unbound connect rather than treating
                                      ;; the whole probe as dead.
                                      (ignore-errors
                                       (sb-bsd-sockets:socket-bind sock local-ip 0)))
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
  ;;; Exit IP / geo lookup (multihop detection)
  ;;; ---------------------------------------------------------------------

(defun json-string-field (json key)
  "Naive extraction of a top-level string field from a flat JSON object.
Good enough for trusted, simple API responses (no escaped quotes in values)."
  (let ((needle (format nil "\"~a\":\"" key)))
    (let ((pos (search needle json)))
      (when pos
        (let* ((start (+ pos (length needle)))
               (end   (position #\" json :start start)))
          (when end (subseq json start end)))))))

(defun resolve-ip (host)
  "Resolve HOST to a dotted-quad string, or NIL if it fails."
  (ignore-errors
   (let ((addr (car (sb-bsd-sockets:host-ent-addresses
                     (sb-bsd-sockets:get-host-by-name host)))))
     (format nil "~{~d~^.~}" (coerce addr 'list)))))

(defun exit-ip-info (socks-port &key (timeout 6))
  "Query ip-api.com through the local SOCKS5 proxy on SOCKS-PORT.
Returns (values ip country) or (values nil nil) on any failure."
  (multiple-value-bind (code out err)
      (run-and-capture (list "curl" "-sS"
                             "--socks5-hostname" (format nil "127.0.0.1:~a" socks-port)
                             "--max-time" (princ-to-string timeout)
                             "http://ip-api.com/json?fields=status,country,query")
                       :timeout (+ timeout 3))
    (declare (ignore err))
    (if (and (eql code 0) out (search "\"status\":\"success\"" out))
        (values (json-string-field out "query") (json-string-field out "country"))
        (values nil nil))))

(defun ip-geo-country (ip &key (timeout 5))
  "Query ip-api.com directly (no proxy) for IP's country. Returns country string or NIL.
Sourced from the physical interface (see BYPASS-LOCAL-IP) so it isn't answered
from the VPN's exit point when a system VPN is active."
  (when ip
    (multiple-value-bind (code out err)
        (run-and-capture (append (list "curl" "-sS" "--max-time" (princ-to-string timeout))
                                 (let ((bip (bypass-local-ip)))
                                   (when bip (list "--interface" bip)))
                                 (list (format nil "http://ip-api.com/json/~a?fields=status,country" ip)))
                         :timeout (+ timeout 3))
      (declare (ignore err))
      (when (and (eql code 0) out (search "\"status\":\"success\"" out))
        (json-string-field out "country")))))

  ;;; ---------------------------------------------------------------------
  ;;; Stability probe — repeated lightweight requests through the SAME
  ;;; already-open socks proxy (no new xray process).
  ;;; ---------------------------------------------------------------------

(defparameter *stability-urls*
  '("https://www.youtube.com/generate_204"
    "https://www.gstatic.com/generate_204"))

(defun stability-probe-once (socks-port url timeout)
  "Lightweight GET through SOCKS-PORT. Returns (values ok ms err)."
  (multiple-value-bind (code out err)
      (run-and-capture (list "curl" "-sS" "-o" "/dev/null"
                             "--socks5-hostname" (format nil "127.0.0.1:~a" socks-port)
                             "--max-time" (princ-to-string timeout)
                             "-w" "%{http_code} %{time_total}"
                             url)
                       :timeout (+ timeout 3))
    (declare (ignore err))
    (if (and (eql code 0) out)
        (let* ((trimmed (string-trim '(#\Space #\Newline) out))
               (parts   (last (str-split trimmed #\Space) 2)))
          (if (= (length parts) 2)
              (let* ((http-code (first parts))
                     (seconds   (let ((*read-default-float-format* 'double-float))
                                  (ignore-errors (read-from-string (second parts))))))
                (if (and (member http-code '("200" "204") :test #'string=) seconds)
                    (values t (* 1000 seconds) nil)
                    (values nil nil (format nil "http=~a" http-code))))
              (values nil nil (format nil "unexpected curl output: ~s" out))))
        (values nil nil (format nil "curl exit=~a" code)))))

(defun mean (lst) (/ (reduce #'+ lst) (float (length lst) 1.0d0)))

(defun stddev (lst)
  (let ((m (mean lst)))
    (sqrt (mean (mapcar (lambda (x) (expt (- x m) 2)) lst)))))

(defun test-config-stability (socks-port &key (urls *stability-urls*)
                                              (rounds 5) (interval 1.5)
                                              (timeout 5) (max-failures 1)
                                              (max-jitter-ms 400.0d0)
                                              (verbose t))
  "Fires ROUNDS lightweight probes through SOCKS-PORT, spaced INTERVAL apart.
Returns (values stable-p stats-plist)."
  (let ((latencies '()) (failures 0) (n (length urls)))
    (dotimes (i rounds)
      (let ((url (nth (mod i n) urls)))
        (multiple-value-bind (ok ms err) (stability-probe-once socks-port url timeout)
          (if ok
              (push ms latencies)
              (progn (incf failures)
                     (when verbose (format t "fail(~a) " err) (force-output))))))
      (when (< i (1- rounds)) (sleep interval)))
    (let* ((lat      (nreverse latencies))
           (jit      (if (>= (length lat) 2) (stddev lat) 0.0d0))
           (stable-p (and (<= failures max-failures) (< jit max-jitter-ms))))
      (values stable-p (list :rounds rounds :failures failures
                             :latencies-ms lat :jitter-ms jit)))))

(defun graceful-kill (proc &key (grace-period 1.0))
  "Terminate PROC cleanly: SIGTERM first, giving it GRACE-PERIOD seconds
to close its own connections (e.g. the proxy session to the test server),
falling back to SIGKILL only if it's still alive after that. A hard
SIGKILL drops the TCP/TLS session to the proxy server without a proper
close, which can leave the server-side connection slot lingering past
its timeout — some public servers cap concurrent connections per IP, so
an abrupt teardown here can make a perfectly live config look 'already
connected, refused' the next time you actually try to use it (e.g. in
v2box) shortly after a speedtest run."
  (when (sb-ext:process-alive-p proc)
    (sb-ext:process-kill proc 15 :pid) ; SIGTERM
    (let ((deadline (+ (get-internal-real-time)
                       (* grace-period internal-time-units-per-second))))
      (loop while (and (sb-ext:process-alive-p proc)
                       (< (get-internal-real-time) deadline))
            do (sleep 0.05)))
    (when (sb-ext:process-alive-p proc)
      (sb-ext:process-kill proc 9 :pid))))

  ;;; ---------------------------------------------------------------------
  ;;; Test one URI end-to-end
  ;;; ---------------------------------------------------------------------

(defparameter *console-lock* (sb-thread:make-mutex :name "speedtest-console")
  "Serializes writes to the real console across parallel worker threads.
TEST-ONE-CONFIG buffers all of its progress lines (including the ones
FORMAT'd deep inside TEST-CONFIG-STABILITY / STABILITY-PROBE-ONCE, since
those inherit whatever *STANDARD-OUTPUT* is dynamically bound to in the
calling thread) into a private string stream, then flushes that whole
buffer in one atomic write here. Without this, N parallel workers all
FORMAT-ing to the same shared stream interleave character-by-character
instead of line-by-line, which is what made the console log unreadable
once *SPEEDTEST-JOBS* went above 1.")

(defun test-one-config (uri &key (test-urls *test-urls*) (dl-timeout *download-timeout*)
                                 (verbose t) (index nil) (total nil))
  (let* ((real-output *standard-output*)
         (prefix (if (and index total)
                     (format nil "[~a/~a] " index total)
                     ""))
         (cfg (ignore-errors (parse-config-uri uri)))
         (log-stream (and verbose (make-string-output-stream))))
    (unwind-protect
        (let ((*standard-output* (or log-stream *standard-output*)))
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
                                   (multiple-value-bind (exit-ip exit-country)
                                       (exit-ip-info socks-port)
                                     (let* ((host-ip (resolve-ip (proxy-config-host cfg)))
                                            (host-country (ip-geo-country host-ip))
                                            (multihop-p (and host-ip exit-ip
                                                             (not (string= host-ip exit-ip)))))
                                       (when verbose
                                         (format t "~,2fMbps~%" mbps)
                                         (format t "      stability ... ") (force-output))
                                       (multiple-value-bind (stable-p stab-stats)
                                           (test-config-stability socks-port :verbose verbose)
                                         (when verbose
                                           (format t "~a (fail=~a jitter=~,0fms)~%"
                                                   (if stable-p "STABLE" "UNSTABLE")
                                                   (getf stab-stats :failures)
                                                   (getf stab-stats :jitter-ms))
                                           (force-output))
                                         (list :uri uri
                                               :status (if stable-p :stable :unstable)
                                               :cfg cfg
                                               :seconds seconds :bytes bytes :mbps mbps
                                               :host-ip host-ip :host-country host-country
                                               :exit-ip exit-ip :exit-country exit-country
                                               :multihop-p multihop-p
                                               :stability stab-stats)))))
                                 (progn
                                   (when verbose
                                     (format t "FAIL (~a)~%" err)
                                     (force-output))
                                   (list :uri uri :status :proxy-dead :cfg cfg :error err)))))))
                (graceful-kill proc)
                (sb-ext:process-wait proc)
                (ignore-errors (delete-file config-path))))))
      (when log-stream
        (sb-thread:with-mutex (*console-lock*)
          (write-string (get-output-stream-string log-stream) real-output)
          (force-output real-output))))))

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
