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
