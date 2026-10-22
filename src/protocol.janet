(import spork/base64 :as native-base64)
(import spork/json :as native-json)
(import spork/utf8 :as utf8)

(def version 3)

(defn limits [value]
  (assert (and (int? (value "frameBytes")) (<= 1 (value "frameBytes") 0x7fffffff)) "InvalidLimits")
  (assert (and (number? (value "admissionSeconds")) (< 0 (value "admissionSeconds") math/inf)) "InvalidLimits")
  value)

(defn- program [value]
  (when (has-key? value "command")
    (assert (and (indexed? (value "command")) (> (length (value "command")) 0)) "InvalidProgram"))
  (each k ["sourceDir" "entryModule" "entry"]
    (assert (and (string? (value k)) (> (length (value k)) 0) (not (string/find "\0" (value k)))) "InvalidProgram"))
  (def dependencies (get value "dependencies" {}))
  (assert (dictionary? dependencies) "InvalidProgram")
  (each [prefix path] (pairs dependencies)
    (assert (and (string? prefix) (not= "" prefix) (not (string/find "/" prefix)) (not (string/find "\0" prefix))
                 (string? path) (> (length path) 0) (not (string/find "\0" path))) "InvalidProgram"))
  value)

(defn base64 [bytes &opt decode]
  (def bound ((dyn :pa/limits) "frameBytes"))
  (assert (and (index-of (type bytes) [:string :buffer]) (<= (length bytes) bound)) "InvalidBytes")
  (if decode (native-base64/decode bytes)
    (do
      (assert (<= (* 4 (math/ceil (/ (length bytes) 3))) bound) "TransportLimit")
      (native-base64/encode bytes))))

(defn request [value]
  (assert (dictionary? value) "InvalidProtocol")
  (assert (= version (value "version")) "InvalidProtocol")
  (program (value "program"))
  (each key ["input" "config"] (assert (string? (value key)) "InvalidProtocol"))
  value)

(defn json [value &opt decode]
  (def bytes (if decode value (native-json/encode value)))
  (assert (and (bytes? bytes) (<= (+ (length bytes) (if decode 0 2)) ((dyn :pa/limits) "frameBytes")) (utf8/is-valid? bytes)) "TransportLimit")
  (if decode (native-json/decode bytes) (string bytes)))

(defn frame [type & pairs] (table "version" version "type" type ;pairs))

(defn event [value]
  (def fields (or (get {"ready" [] "emit" ["output"] "result" ["output"] "diagnostic" ["level" "code" "message"] "error" ["code" "message"]} (get value "type")) (error "InvalidProtocol")))
  (assert (= version (value "version")) "InvalidProtocol")
  (each key fields (assert (string? (value key)) "InvalidProtocol"))
  (when (has-key? value "output") (base64 (value "output") true))
  (when (has-key? value "detail") (assert (string? (value "detail")) "InvalidProtocol"))
  (when (has-key? value "context") (assert (dictionary? (value "context")) "InvalidProtocol"))
  (when (= "diagnostic" (value "type")) (assert (index-of (value "level") ["debug" "info" "warn"]) "InvalidProtocol"))
  value)

(defn send [io value]
  (:write io (string (json value) "\n"))
  (when (get io :flush) (:flush io)))

(defn reader [io &opt events] @{:io io :bytes @"" :events events})

(defn receive [state]
  (def bound ((dyn :pa/limits) "frameBytes"))
  (var line (string/find "\n" (state :bytes)))
  (while (nil? line)
    (assert (< (length (state :bytes)) bound) "TransportLimit")
    (def chunk (:read (state :io) (min 4096 (- bound (length (state :bytes))))))
    (unless chunk
      (assert (and (= 0 (length (state :bytes))) (or (not (state :events)) (state :terminal))) "InvalidProtocol")
      (break))
    (buffer/push-string (state :bytes) chunk)
    (set line (string/find "\n" (state :bytes))))
  (when line
    (def bytes (string/slice (state :bytes) 0 line))
    (put state :bytes (buffer (string/slice (state :bytes) (+ line 1))))
    (def value (json bytes true))
    (when (state :events)
      (event value)
      (assert (not (state :terminal)) "InvalidProtocol")
      (case (value "type")
        "ready" (do (assert (not (state :ready)) "InvalidProtocol") (put state :ready true))
        (assert (or (state :ready) (index-of (value "type") ["diagnostic" "error"])) "InvalidProtocol"))
      (when (index-of (value "type") ["result" "error"]) (put state :terminal value)))
    value))

(defn diagnostic [type err & fields]
  (def result (frame type "code" (if (and (dictionary? err) (string? (err :code))) (err :code) "ProgramError")
                     "message" (if (and (dictionary? err) (string? (err :message))) (err :message) (if (string? err) err (string/format "%n" err))) ;fields))
  (when (dictionary? err)
    (each key [:detail :context] (when (err key) (put result (string key) (err key)))))
  (def size (+ 2 (length (native-json/encode result))))
  (if (<= size ((dyn :pa/limits) "frameBytes")) result
    (frame type "code" "DiagnosticTooLarge" "message" "Diagnostic exceeds frameBytes; increase the boundary limit."
           "context" {:bytes size} ;fields)))
