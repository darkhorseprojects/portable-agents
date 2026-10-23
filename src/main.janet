(import ./protocol :as p)
(import ./markdown :as md)
(import portable-agents/host :as host)

(var- observing true)
(var- accepted false)
(var- output stdout)
(unless (index-of (os/which) [:windows :mingw]) (os/sigaction :pipe (fn [])))

(defn- publish [frame]
  (def bytes (string (p/json frame) "\n"))
  (when observing
    (try (do (file/write output bytes) (file/flush output)) ([err] (set observing false)))))

(defn- emit [bytes]
  (assert accepted "MissingAdmission")
  (publish (p/frame "emit" "output" (p/base64 bytes))))

(defn- diagnostic [level value]
  (publish (p/diagnostic "diagnostic" value "level" level)))

(defn execute [request limits executable]
  (set output (host/protocol-output))
  (with-dyns [:pa/limits limits]
    (try
      (do
        (def input (p/base64 (request "input") true))
        (def config (p/base64 (request "config") true))
        (def base (make-env))
        (put base :pa/executable executable)
        (put base :pa/limits limits)
        (put base :pa/program (request "program"))
        (put base *syspath* (os/realpath ((request "program") "sourceDir")))
        (each [name root] (pairs (get (request "program") "dependencies" {}))
          (put base (keyword name) (os/realpath root)))
        (put base 'pa/emit @{:value emit :private true})
        (put base 'pa/diagnostic @{:value diagnostic :private true})
        (put module/loaders :markdown md/load)
        (put base *module-make-env* (partial make-env base))
        (with-env base
          (with-dyns [:out (fn [bytes] (diagnostic "debug" {:code "Output" :message (string bytes)}))
                      :err (fn [bytes] (diagnostic "warn" {:code "Stderr" :message (string bytes)}))]
            (module/add-paths ".md" :markdown)
            (module/add-file-extension ".md" :markdown)
            (def env (require (string (base *syspath*) "/" ((request "program") "entryModule"))))
            (def name (symbol ((request "program") "entry")))
            (assert (and (has-key? env name) (not ((env name) :private)) (not ((env name) :macro))) "UnknownEntry")
            (def target (module/value env name))
            (assert (index-of (type target) [:function :cfunction]) "NotCallable")
            (set accepted true)
            (publish (p/frame "ready"))
            (def result (with-env env (target input config)))
            (publish (p/frame "result" "output" (p/base64 result))))))
      ([err fiber]
        (def trace @"")
        (with-dyns [:err (fn [bytes] (buffer/push-string trace bytes))] (debug/stacktrace fiber))
        (publish (p/diagnostic "error" (if (dictionary? err) (merge err {:detail (string (or (err :detail) "") "\n" trace)})
                                         {:code "ProgramError" :message (if (string? err) err (string/format "%n" err)) :detail (string trace)}))))))
  (os/exit 0 true))

(defn main [executable operation & args]
  (assert (and (index-of operation ["spawn" "execute"]) (= 2 (length args)))
          "usage: agent spawn FRAME-BYTES ADMISSION-SECONDS")
  (def limits (p/limits (table ;(interleave ["frameBytes" "admissionSeconds"] (map scan-number args)))))
  (when-let [library (os/getenv "JANET_PATH")] (module/add-syspath library))
  (def path (host/executable))
  (when (= operation "execute") (host/detach))
  (with-dyns [:pa/limits limits]
    (def reader (p/reader stdin))
    (def request (p/request (p/receive reader)))
    (assert (not (p/receive reader)) "InvalidProtocol")
    (if (and (= operation "execute") (not (get-in request ["program" "command"])))
      (execute request limits path)
      (do
        (def command (get-in request ["program" "command"]))
        (def child (os/spawn
                     (if command
                       [;command "-e" `
(import portable-agents/src/main)
(import portable-agents/src/protocol :as p)
(def limits
  (p/limits
    (table ;(interleave ["frameBytes" "admissionSeconds"]
                       (map scan-number (tuple/slice (dyn :args) 2))))))
(with-dyns [:pa/limits limits]
  (main/execute (p/request (p/receive (p/reader stdin)))
                limits
                (os/getenv "PA_EXECUTABLE")))
` ;args]
                       [path "execute" ;args])
                     :pde (merge (os/environ) {"PA_EXECUTABLE" path
                                               :in :pipe :out :pipe :err stderr})))
        (def exited (ev/chan 1))
        (ev/go (fn [] (os/proc-wait child)) nil exited)
        (defer (ev/close (child :in)) (p/send (child :in) request))
        (def output (p/reader (child :out) true))
        (ev/with-deadline (limits "admissionSeconds")
          (while true
            (def frame (p/receive output))
            (publish frame)
            (when (index-of (frame "type") ["ready" "error"]) (break))))
        (defer (ev/close (child :out))
          (var frame nil)
          (while (set frame (p/receive output)) (publish frame))
          (ev/take exited)
          (os/exit (child :return-code)))))))
