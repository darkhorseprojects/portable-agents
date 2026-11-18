(import spork/json :as json)
(import spork/utf8 :as utf8)

(defn- envelope [value]
  (assert (dictionary? value) "invalid protocol message")
  (def fields (get {"call" [:id :caller :method :params] "ready" [:handle]
                   "result" [:id :value] "error" [:id :error]} (value :type)))
  (assert (and fields (every? (map |(has-key? value $) fields))
    (every? (map |(index-of $ (array/concat @[:type] fields)) (keys value)))) "invalid protocol envelope")
  (each key (filter |(index-of $ fields) [:id :caller :method :handle])
    (assert (and (string? (value key)) (> (length (value key)) 0) (utf8/is-valid? (value key))) "invalid protocol identity"))
  (when (= "error" (value :type))
    (def diagnostic (value :error))
    (assert (and (dictionary? diagnostic) (string? (diagnostic :code)) (string? (diagnostic :message))
      (every? (map |(index-of $ [:code :message :detail :context]) (keys diagnostic)))
      (or (not (has-key? diagnostic :detail)) (string? (diagnostic :detail)))
      (or (not (has-key? diagnostic :context)) (dictionary? (diagnostic :context)))) "invalid diagnostic")
    (each key [:code :message :detail]
      (when (has-key? diagnostic key) (assert (utf8/is-valid? (diagnostic key)) "invalid diagnostic"))))
  value)

(defn read
  "Reads one bounded UTF-8 JSON envelope. pending is a connection-local buffer. Returns nil at clean EOF."
  [stream pending maximum-bytes]
  (assert (and (int? maximum-bytes) (<= 1 maximum-bytes 0x7fffffff)) "invalid frame limit")
  (var newline (string/find "\n" pending))
  (while (nil? newline)
    (assert (< (length pending) maximum-bytes) "frame exceeds byte limit")
    (def chunk (:read stream (if (= :core/file (type stream)) 1 (min 4096 (- maximum-bytes (length pending))))))
    (unless chunk
      (assert (= 0 (length pending)) "partial frame")
      (break))
    (buffer/push-string pending chunk)
    (set newline (string/find "\n" pending)))
  (when newline
    (assert (< newline maximum-bytes) "frame exceeds byte limit")
    (def bytes (string/slice pending 0 newline))
    (def remaining (string/slice pending (+ newline 1)))
    (buffer/clear pending)
    (buffer/push-string pending remaining)
    (assert (utf8/is-valid? bytes) "invalid UTF-8")
    (envelope (json/decode bytes true))))

(defn write
  "Validates and writes one complete bounded UTF-8 JSON envelope."
  [stream message maximum-bytes]
  (assert (and (int? maximum-bytes) (<= 1 maximum-bytes 0x7fffffff)) "invalid frame limit")
  (def bytes (string (json/encode (envelope message)) "\n"))
  (assert (and (<= (length bytes) maximum-bytes) (utf8/is-valid? bytes)) "invalid or oversized frame")
  (:write stream bytes)
  (when (get stream :flush) (:flush stream)))

(defn diagnostic [err &opt fiber]
  (def d (if (and (dictionary? err) (string? (err :code)) (string? (err :message)))
    (tabseq [key :in [:code :message :detail :context] :when (has-key? err key)] key (err key))
    @{:code "ExecutionFailed" :message (string err)}))
  (when (and fiber (not (d :detail)))
    (def trace @"") (with-dyns [:err trace] (debug/stacktrace fiber)) (put d :detail (string trace))) d)

(defn serve [handle maximum handler]
  (def incoming (ev/thread-chan 256)) (def outgoing (ev/thread-chan 256))
  (def pending @{}) (def active @{})
  (ev/thread (fn [[incoming maximum]]
    (try (do (def bytes @"") (var message nil)
      (while (set message (read stdin bytes maximum)) (ev/give incoming message)) (os/exit 0 true))
      ([err fiber] (eprint (json/encode (diagnostic err fiber))) (os/exit 1 true)))) [incoming maximum] :n)
  (ev/thread (fn [[outgoing maximum]]
    (try (while true (write stdout (ev/take outgoing) maximum))
      ([err fiber] (eprint (json/encode (diagnostic err fiber))) (os/exit 1 true)))) [outgoing maximum] :n)
  (ev/give outgoing {:type "ready" :handle handle})
  (while true
    (def message (ev/take incoming))
    (if (= "call" (message :type))
      (do
        (assert (and (not (active (message :id))) (not (string/find "/" (message :id)))) "invalid root call identity")
        (put active (message :id) true)
        (ev/go (fn []
          (var sequence 0) (var opened true) (var outstanding 0) (def drained (ev/chan 1))
          (def reverse (fn [method params]
            (assert opened "invocation has ended")
            (def id (string (message :id) "/" (++ sequence))) (def reply (ev/chan 1))
            (put pending id reply) (++ outstanding)
            (defer (do (ev/chan-close reply) (-- outstanding)
                (when (and (not opened) (= 0 outstanding)) (ev/give drained true)))
              (ev/give outgoing {:type "call" :id id :caller handle :method method :params (if (nil? params) :null params)})
              (def result (ev/take reply))
              (when (result :error) (error (result :error)))
              (postwalk |(if (= $ :null) nil $) (result :value)))))
          (def response (try
            (let [value (handler message reverse)]
              {:type "result" :id (message :id) :value (if (nil? value) :null value)})
            ([err fiber] {:type "error" :id (message :id) :error (diagnostic err fiber)})))
          (set opened false)
          (while (> outstanding 0) (ev/take drained)) (ev/chan-close drained)
          (put active (message :id) nil) (ev/give outgoing response))))
      (do
        (assert (index-of (message :type) ["result" "error"]) "unexpected envelope")
        (def reply (pending (message :id))) (assert reply "unexpected response")
        (put pending (message :id) nil) (ev/give reply message)))))
