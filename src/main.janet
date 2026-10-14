(import ./protocol :as p)
(import ./markdown :as md)

(var- observing true)

(defn- publish [frame]
  (def bytes (string (p/json (p/event frame)) "\n"))
  (assert (<= (+ 1 (length bytes)) ((dyn :pa/limits) "frameBytes")) "TransportLimit")
  (when observing
    (try (do (file/write stdout bytes) (file/flush stdout)) ([err] (set observing false)))))

(defn- emit [bytes &opt mode]
  (assert (index-of mode [nil :append]) "InvalidEmitMode")
  (when (dyn :pa/observe)
    (publish (p/frame (if mode "append" "emit") "output" (p/base64 bytes)))))

(defn- log [stage]
  (when (dyn :pa/observe) (publish (p/frame "log" "stage" stage))))

(defn- module-env [] (make-env (dyn :pa/environment)))

(defn main [& args]
  (def limits (p/limits (table ;(interleave ["frameBytes" "depth" "admissionSeconds"] (map scan-number args)))))
  (unless (index-of (os/which) [:windows :mingw]) (os/sigaction :pipe (fn [])))
  (with-dyns [:pa/limits limits]
    (var diagnostics true)
    (try
      (do
        (def reader (p/reader stdin))
        (def request (p/request (p/receive reader)))
        (set diagnostics (request "observe"))
        (assert (not (p/receive reader)) "InvalidProtocol")
        (def base (make-env))
        (put base :pa/limits limits)
        (put base :pa/observe (request "observe"))
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
        (when diagnostics (publish (p/diagnostic "traceback" (string trace))))
        (publish (p/diagnostic "error" err)))))
  (os/exit 0))
