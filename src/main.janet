(import ../lib/portable-agents/protocol :as p)
(import ../lib/portable-agents/markdown :as md)
(import spork/sh :as sh)
(import spork/path :as path)
(import portable-agents/host :as host)

(defn- sinks [output]
  (var observing true)
  (var logging true)
  (defn publish [frame]
    (when observing
      (def bytes (string (p/json frame) "\n"))
      (try (do (file/write output bytes) (file/flush output)) ([err] (set observing false)))))
  [publish
   (fn [bytes] (when observing (publish {"version" p/version "type" "stdout" "output" (p/base64 bytes)})))
   (fn [bytes] (when logging (try (do (file/write stderr bytes) (file/flush stderr)) ([err] (set logging false)))))])

(defn main [executable operation & args]
  (assert (and (= operation "run") (= 2 (length args))) "usage: agent run FRAME-BYTES ADMISSION-SECONDS")
  (def limits (table ;(interleave ["frameBytes" "admissionSeconds"] (map scan-number args))))
  (assert (and (int? (limits "frameBytes")) (<= 1 (limits "frameBytes") 0x7fffffff)
               (number? (limits "admissionSeconds")) (< 0 (limits "admissionSeconds") math/inf)) "InvalidLimits")
  (unless (index-of (os/which) [:windows :mingw]) (os/sigaction :pipe (fn [])))
  (host/detach)
  (def [publish out log] (sinks (host/protocol-output)))
  (md/register)
  (when-let [library (os/getenv "JANET_PATH")] (module/add-syspath library))
  (with-dyns [:pa/limits limits]
    (try
      (do
        (def reader (p/reader stdin))
        (def request (p/request (p/receive reader)))
        (assert (not (p/receive reader)) "InvalidProtocol")
        (def input (p/base64 (request "input") true))
        (def config (p/base64 (request "config") true))
        (def program (request "program"))
        (put program "sourceDir" (os/realpath (program "sourceDir")))
        (def base (make-env))
        (put base :pa/executable (if (= executable (path/basename executable)) (sh/self-exe) (os/realpath executable)))
        (put base :pa/limits limits)
        (put base :pa/program program)
        (put base *syspath* (program "sourceDir"))
        (each [name root] (pairs (get program "dependencies" {}))
          (def root (os/realpath root))
          (put (program "dependencies") name root)
          (put base (keyword name) root))
        (put base :out out)
        (put base :err log)
        (put base *module-make-env* (partial make-env base))
        (with-env base
          (def env (require (string (base *syspath*) "/" (program "entryModule"))))
          (def name (symbol (program "entry")))
          (assert (and (has-key? env name) (not ((env name) :private)) (not ((env name) :macro))) "UnknownEntry")
          (def target (module/value env name))
          (assert (index-of (type target) [:function :cfunction]) "NotCallable")
          (publish {"version" p/version "type" "ready"})
          (def result (with-env env (target input config)))
          (publish {"version" p/version "type" "result" "output" (p/base64 result)})))
      ([err fiber]
        (def trace @"")
        (with-dyns [:err trace] (debug/stacktrace fiber))
        (publish (p/failure (if (dictionary? err) (merge err {:detail (string (or (err :detail) "") "\n" trace)})
                             {:code "ProgramError" :message (if (string? err) err (string/format "%n" err)) :detail (string trace)}))))))
  (os/exit 0 true))
