;;;; singbox-outbound.lisp
;;;;
;;;; Sing-box's outbound JSON schema, not xray's. Same proxy-config struct
;;;; and parse-config-uri as speedtest-configs.lisp (loaded below if not
;;;; already present) — only the JSON shape differs: sing-box puts
;;;; server/server_port/uuid directly on the outbound object, and TLS/
;;;; reality/transport are nested under tls/transport instead of xray's
;;;; separate streamSettings block. See:
;;;; https://sing-box.sagernet.org/configuration/outbound/vless/
;;;; https://sing-box.sagernet.org/configuration/outbound/shadowsocks/
;;;;
;;;; This file only builds JSON strings — it doesn't touch *config-path*,
;;;; *proxy-server-ip*, or run anything. dog.lisp wires the result into
;;;; *config-pool* and switch-to-config does the actual swap.

(let ((here (or *load-truename* *load-pathname*
                (error "singbox-outbound.lisp must be loaded via (load ...)"))))
  (unless (fboundp 'parse-config-uri)
    (load (merge-pathnames "../speedtest-configs.lisp" here))))

;;; --- sing-box outbound builders ---

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

(defun singbox-transport-fields (extra network)
  "Returns an alist of (\"transport\" . <obj>) or nil for plain tcp."
  (cond
    ((string= network "ws")
     (list (cons "transport"
                 (list :obj
                       (cons "type" "ws")
                       (cons "path" (qval extra "path" "/"))
                       (cons "headers" (list :obj (cons "Host" (qval extra "host" ""))))))))
    ((string= network "grpc")
     (list (cons "transport"
                 (list :obj
                       (cons "type" "grpc")
                       (cons "service_name" (qval extra "serviceName" ""))))))
    (t nil)))

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
           ;; flow only makes sense with reality+tcp (xtls-rprx-vision);
           ;; omit the key entirely rather than send an empty string —
           ;; sing-box treats an empty flow differently from an absent one.
           (when (plusp (length flow)) (list (cons "flow" flow)))
           (singbox-tls-fields cfg extra security)
           (singbox-transport-fields extra network)))))

(defun shadowsocks-outbound-singbox (cfg)
  (list :obj
        (cons "type" "shadowsocks")
        (cons "tag" "proxy")
        (cons "server" (proxy-config-host cfg))
        (cons "server_port" (proxy-config-port cfg))
        (cons "method" (proxy-config-method cfg))
        (cons "password" (proxy-config-password cfg))))

(defun proxy-outbound-singbox (cfg)
  (ecase (proxy-config-kind cfg)
    (:vless       (vless-outbound-singbox cfg))
    (:shadowsocks (shadowsocks-outbound-singbox cfg))))

;;; --- full config, following the README's fixed contract ---
;;;
;;; tag "proxy" / dns detour "proxy" / mixed inbound on 127.0.0.1:1080 —
;;; must match *socks-port* in singbox-ctl.lisp. The only thing that
;;; varies between pool entries is outbounds[0], built above.

(defun build-singbox-config (cfg)
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
                          (cons "listen_port" 1080))))
        (cons "outbounds" (list :arr (proxy-outbound-singbox cfg)))))

;;; --- .txt -> pool ---

(defun read-uri-lines (txt-path)
  "One vless://or ss:// URI per line. Blank lines and lines starting with
   # are ignored, so you can comment things out or leave notes."
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
