(import ./protocol :as p)
(import ./markdown :as md)
(import portable-agents/host :as host)

(var- observing true)
(var- accepted false)

(defn- publish [frame]
  (def bytes (string (p/json frame) "\n"))
  (assert (<= (+ 1 (length bytes)) ((dyn :pa/limits) "frameBytes")) "TransportLimit")
  (when observing
    (try (do (file/write stdout bytes) (file/flush stdout)) ([err] (set observing false)))))

(defn- emit [bytes]
  (assert accepted "MissingAdmission")
  (publish (p/frame "emit" "output" (p/base64 bytes))))

(defn- log [stage]
  (publish (p/frame "log" "stage" stage)))

(defn- module-env [] (make-env (dyn :pa/environment)))

(defn execute [request limits executable]
  (set observing true)
  (set accepted false)
  (unless (index-of (os/which) [:windows :mingw]) (os/sigaction :pipe (fn [])))
  (with-dyns [:pa/limits limits]
    (try
      (do
        (def base (make-env))
        (put base :pa/executable executable)
        (put base :pa/limits limits)
        (put base :pa/program (request "program"))
        (put base :pa/environment base)
        (put base *syspath* (os/realpath ((request "program") "sourceDir")))
        (each [name root] (pairs (get (request "program") "dependencies" {}))
          (put base (keyword name) (os/realpath root)))
        (put base 'pa/emit @{:value emit :private true})
        (put base 'pa/log @{:value log :private true})
        (put module/loaders :markdown md/load)
        (put base *module-make-env* module-env)
        (with-env base
          (with-dyns [:out stderr :err stderr]
            (module/add-paths ".md" :markdown)
            (module/add-file-extension ".md" :markdown)
            (def env (require (string (base *syspath*) "/" ((request "program") "entryModule"))))
            (def name (symbol ((request "program") "entry")))
            (assert (and (has-key? env name) (not ((env name) :private)) (not ((env name) :macro))) "UnknownEntry")
            (def target (module/value env name))
            (assert (index-of (type target) [:function :cfunction]) "NotCallable")
            (set accepted true)
            (publish (p/frame "ready"))
            (def output (with-env env
              (with-dyns [:out stderr :err stderr]
                (target (p/base64 (request "input") true) (p/base64 (request "config") true)))))
            (publish (p/frame "result" "output" (p/base64 output))))))
      ([err fiber]
        (def trace @"")
        (with-dyns [:err (fn [bytes]
          (buffer/push-string trace (string/slice bytes 0 (min (length bytes) (- (limits "frameBytes") (length trace))))))]
          (debug/stacktrace fiber))
        (publish (p/diagnostic "traceback" (string trace)))
        (publish (p/diagnostic "error" err)))))
  (os/exit 0 true))

(defn main [executable operation & args]
  (assert (and (index-of operation ["spawn" "execute"]) (= 3 (length args)))
          "usage: agent spawn FRAME-BYTES DEPTH ADMISSION-SECONDS")
  (def limits (p/limits (table ;(interleave ["frameBytes" "depth" "admissionSeconds"] (map scan-number args)))))
  (unless (index-of (os/which) [:windows :mingw]) (os/sigaction :pipe (fn [])))
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
            [;command "-e" "(import portable-agents/src/main) (import portable-agents/src/protocol :as p) (def limits (p/limits (table ;(interleave [\"frameBytes\" \"depth\" \"admissionSeconds\"] (map scan-number (tuple/slice (dyn :args) 2)))))) (with-dyns [:pa/limits limits] (main/execute (p/request (p/receive (p/reader stdin))) limits (os/getenv \"PA_EXECUTABLE\")))" ;args]
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
