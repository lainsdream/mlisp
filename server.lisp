(defpackage :my-server
  (:use :cl))
(in-package :my-server)

;;; ============================================================
;;; Игра "Жизнь" Конвея (адаптировано из кода, который показан
;;; на экране HandiNAVI в Serial Experiments Lain, Layer:07)
;;; ============================================================

(defparameter *life-size* 12) ;; размер поля N x N

(defparameter *glider*
  ;; Начальная позиция: классический "глайдер" в углу 12x12 поля.
  ;; 1 = живая клетка, 0 = мёртвая
  (let ((field (make-array (list *life-size* *life-size*)
                           :element-type 'bit
                           :initial-element 0)))
    (setf (aref field 1 2) 1)
    (setf (aref field 2 3) 1)
    (setf (aref field 3 1) 1)
    (setf (aref field 3 2) 1)
    (setf (aref field 3 3) 1)
    field))

(defun count-neighbors (field i j size)
  "Считает живых соседей клетки (i,j), с 'заворачиванием' краёв поля."
  (let ((count 0))
    (dolist (di '(-1 0 1))
      (dolist (dj '(-1 0 1))
        (unless (and (= di 0) (= dj 0))
          (let ((ni (mod (+ i di) size))
                (nj (mod (+ j dj) size)))
            (incf count (aref field ni nj))))))
    count))

(defun next-generation (field size)
  "Возвращает новое поле — следующее поколение по правилам Конвея."
  (let ((next (make-array (list size size) :element-type 'bit :initial-element 0)))
    (dotimes (i size)
      (dotimes (j size)
        (let ((alive (= 1 (aref field i j)))
              (neighbors (count-neighbors field i j size)))
          (setf (aref next i j)
                (if alive
                    (if (or (= neighbors 2) (= neighbors 3)) 1 0)
                    (if (= neighbors 3) 1 0))))))
    next))

(defun advance-to-generation (n)
  "Считает состояние поля жизни на N-ом поколении, начиная от глайдера."
  (let ((field *glider*))
    (dotimes (i n)
      (setf field (next-generation field *life-size*)))
    field))

(defun field-to-html (field size)
  "Превращает битовое поле в HTML-таблицу для отображения в браузере."
  (with-output-to-string (s)
    (format s "<table style='border-collapse:collapse'>")
    (dotimes (i size)
      (format s "<tr>")
      (dotimes (j size)
        (format s "<td style='width:16px;height:16px;background:~a'></td>"
                (if (= 1 (aref field i j)) "black" "#eee")))
      (format s "</tr>"))
    (format s "</table>")))

(defun life-page-html (gen)
  "Собирает целую HTML-страницу для показа состояния игры на поколении GEN."
  (let ((field (advance-to-generation gen)))
    (format nil
            "<html><head><meta charset='utf-8'><title>Game of Life</title></head>
<body style='font-family:sans-serif'>
<h2>Игра &quot;Жизнь&quot; Конвея — поколение ~a</h2>
~a
<p><a href='/life?gen=~a'>&larr; Начать заново</a> &nbsp;|&nbsp;
<a href='/life?gen=~a'>Следующее поколение &rarr;</a></p>
</body></html>"
            gen (field-to-html field *life-size*) 0 (1+ gen))))

;;; ============================================================
;;; HTTP-сервер
;;; ============================================================

(defun parse-request-path (request-line)
  "Из строки вида 'GET /life?gen=3 HTTP/1.1' достаёт путь '/life?gen=3'."
  (let* ((first-space (position #\Space request-line))
         (second-space (position #\Space request-line :start (1+ first-space))))
    (subseq request-line (1+ first-space) second-space)))

(defun parse-gen-param (path)
  "Из '/life?gen=3' достаёт число 3. Если параметра нет — возвращает 0."
  (let ((pos (search "gen=" path)))
    (if pos
        (parse-integer path :start (+ pos 4) :junk-allowed t)
        0)))

(defun handle-request (stream)
  "Читает запрос клиента и отправляет подходящий HTTP-ответ."
  (let* ((request-line (read-line stream nil ""))
         (path (if (plusp (length request-line))
                   (parse-request-path request-line)
                   "/")))
    (cond
      ;; Маршрут /life — показываем игру "Жизнь"
      ((and (>= (length path) 5) (string= (subseq path 0 5) "/life"))
       (let* ((gen (or (parse-gen-param path) 0))
              (body (life-page-html gen)))
         (format stream "HTTP/1.1 200 OK~C~C" #\Return #\Linefeed)
         (format stream "Content-Type: text/html; charset=utf-8~C~C~C~C"
                 #\Return #\Linefeed #\Return #\Linefeed)
         (write-string body stream)))
      ;; Все остальные пути — старое приветствие
      (t
       (format stream "HTTP/1.1 200 OK~C~C" #\Return #\Linefeed)
       (format stream "Content-Type: text/plain; charset=utf-8~C~C~C~C"
               #\Return #\Linefeed #\Return #\Linefeed)
       (format stream "Привет из Лиспа! Попробуй перейти на /life~%")))))

(defun start-simple-server (&optional (port 4242))
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket
                               :type :stream
                               :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
    (sb-bsd-sockets:socket-bind socket #(127 0 0 1) port)
    (sb-bsd-sockets:socket-listen socket 5)
    (format t "Server started on http://localhost:~a/~%" port)
    (loop
      (let ((client (sb-bsd-sockets:socket-accept socket)))
        (unwind-protect
             (let ((stream (sb-bsd-sockets:socket-make-stream client :input t :output t)))
               (handle-request stream)
               (close stream))
          (sb-bsd-sockets:socket-close client))))))

(start-simple-server 4242)

