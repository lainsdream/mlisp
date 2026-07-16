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

