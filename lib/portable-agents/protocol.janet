(import spork/base64 :as native-base64)
(import spork/json :as native-json)
(import spork/utf8 :as utf8)

(def version 1)

(defn base64 [bytes &opt decode]
  (def bound ((dyn :pa/limits) "frameBytes"))
  (assert (and (index-of (type bytes) [:string :buffer]) (<= (length bytes) bound)) "InvalidBytes")
  (if decode (native-base64/decode (string bytes))
    (do
      (assert (<= (* 4 (math/ceil (/ (length bytes) 3))) bound) "TransportLimit")
      (native-base64/encode (string bytes)))))

(defn request [value]
  (assert (dictionary? value) "InvalidProtocol")
  (assert (= version (value "version")) "InvalidProtocol")
  (def program (value "program"))
  (assert (not (has-key? program "command")) "UnsupportedProgramCommand")
  (each k ["sourceDir" "entryModule" "entry"]
    (assert (and (string? (program k)) (> (length (program k)) 0) (not (string/find "\0" (program k)))) "InvalidProgram"))
  (def dependencies (get program "dependencies" {}))
  (assert (dictionary? dependencies) "InvalidProgram")
  (each [prefix path] (pairs dependencies)
    (assert (and (string? prefix) (not= "" prefix) (not (string/find "/" prefix)) (not (string/find "\0" prefix))
                 (string? path) (> (length path) 0) (not (string/find "\0" path))) "InvalidProgram"))
  (def imports (get program "imports" {}))
  (assert (dictionary? imports) "InvalidImports")
  (each [name module] (pairs imports)
    (assert (and (string? name) (> (length name) 0) (not (string/find "\0" name))) "InvalidImport")
    (assert (and (dictionary? module) (indexed? (module "command")) (> (length (module "command")) 0)
                 (dictionary? (module "exports"))) "InvalidImport")
    (eachp [index part] (module "command")
      (assert (and (string? part) (or (> index 0) (> (length part) 0)) (not (string/find "\0" part))) "InvalidImport"))
    (each [name documentation] (pairs (module "exports"))
      (assert (and (string? name) (> (length name) 0) (not (string/find "\0" name)) (string? documentation)) "InvalidImport"))
    (def seconds (get module "timeoutSeconds" 0))
    (assert (and (number? seconds) (<= 0 seconds) (< seconds math/inf)) "InvalidImport"))
  (each key ["input" "config"] (assert (string? (value key)) "InvalidProtocol"))
  value)

(defn json [value &opt decode data]
  (def bytes (if decode value (native-json/encode value)))
  (assert (and (bytes? bytes) (<= (+ (length bytes) (if decode 0 1)) ((dyn :pa/limits) "frameBytes")) (utf8/is-valid? bytes)) "TransportLimit")
  (if decode (native-json/decode bytes data data) (string bytes)))

(defn send [io value]
  (:write io (string (json value) "\n"))
  (when (get io :flush) (:flush io)))

(defn reader [io &opt events data] @{:io io :bytes @"" :events events :data data})

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
    (def value (json bytes true (state :data)))
    (when (state :events)
      (def fields (or (get {"ready" [] "stdout" ["output"] "result" ["output"] "error" ["code" "message"]} (get value "type")) (error "InvalidProtocol")))
      (assert (= version (value "version")) "InvalidProtocol")
      (each key fields (assert (string? (value key)) "InvalidProtocol"))
      (when (has-key? value "output") (put value "output" (base64 (value "output") true)))
      (when (has-key? value "detail") (assert (string? (value "detail")) "InvalidProtocol"))
      (when (has-key? value "context") (assert (dictionary? (value "context")) "InvalidProtocol"))
      (assert (not (state :terminal)) "InvalidProtocol")
      (case (value "type")
        "ready" (do (assert (not (state :ready)) "InvalidProtocol") (put state :ready true))
        (assert (or (state :ready) (index-of (value "type") ["stdout" "error"])) "InvalidProtocol"))
      (when (index-of (value "type") ["result" "error"]) (put state :terminal value)))
    value))

(defn output [reader &opt ready]
  (label result
    (var frame nil)
    (while (set frame (receive reader))
      (case (frame "type")
        "stdout" (prin (frame "output"))
        "ready" (when ready (return result reader))))
    (def terminal (reader :terminal))
    (when (= "error" (terminal "type"))
      (error (tabseq [[key value] :in (pairs terminal) :unless (index-of key ["version" "type"])] (keyword key) value)))
    (terminal "output")))

(defn import-module [module]
  (tabseq [[name documentation] :in (pairs (module "exports"))]
    (symbol name) @{:doc documentation :value (fn [& args]
      (def child (os/spawn (module "command") :pd {:in :pipe :out :pipe :err stderr}))
      (def exited (ev/chan 1))
      (ev/go (fn [] (os/proc-wait child)) nil exited)
      (defer (do (ev/close (child :in)) (ev/close (child :out)))
        (def seconds (get module "timeoutSeconds" 0))
        (ev/with-deadline (if (= seconds 0) math/inf seconds)
          (def call @{:version version :export name :arguments args})
          (when-let [operation (dyn :pa/operation)] (put call :operation operation))
          (send (child :in) call)
          (ev/close (child :in))
          (def replies (reader (child :out) nil true))
          (def frame (receive replies))
          (assert (and (dictionary? frame) (= version (frame :version))) "InvalidImportOutcome")
          (assert (not (receive replies)) "TrailingImportOutput")
          (ev/take exited)
          (when (= "error" (frame :type))
            (error (tabseq [[key value] :pairs frame :unless (index-of key [:version :type])] key value)))
          (assert (and (= "result" (frame :type)) (= 0 (child :return-code))) "ImportFailure; effects may have happened")
          (frame :value))))}))

(defn diagnostic [code err &opt fiber]
  (def trace @"")
  (when fiber (with-dyns [:err trace] (debug/stacktrace fiber)))
  (def value (if (and (dictionary? err) (string? (err :code)) (string? (err :message))) err
               {:code code :message (if (string? err) err (string/format "%n" err))}))
  (merge value {:detail (string (or (value :detail) "") "\n" trace)}))

(defn failure [err &opt fiber]
  (def value (diagnostic "ProgramError" err fiber))
  (def result @{"version" version "type" "error"})
  (each key [:code :message :detail :context] (when (value key) (put result (string key) (value key))))
  (def size (+ 1 (length (native-json/encode result))))
  (if (<= size ((dyn :pa/limits) "frameBytes")) result
    {"version" version "type" "error" "code" "ErrorTooLarge"
     "message" "Error exceeds frameBytes; increase the boundary limit." "context" {:bytes size}}))
