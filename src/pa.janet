(import ./protocol :as p)
(import ./markdown :as md)

(assert (>= (cmp (tuple/slice (map scan-number (take 2 (string/split "." janet/version)))) [1 42]) 0) "Janet 1.42+ required")

(def- main-script
  (let [path (os/realpath (dyn :current-file))]
    (string (string/slice path 0 (- (length path) (length "pa.janet"))) "main.janet")))

(defn- future [task]
  (def handle @{:done (ev/chan)})
  (ev/spawn
    (defer (ev/chan-close (handle :done))
      (put handle :outcome (try [true (task)] ([err] [false err])))))
  handle)

(defn await [handle]
  (ev/take (handle :done))
  (def [ok value] (handle :outcome))
  (if ok value (error value)))

(defn- launch [request launcher independent &opt quiet]
  (def limits (dyn :pa/limits))
  (var listener (unless independent (net/listen "127.0.0.1" 0 :stream true)))
  (def candidates @{})
  (def admitted (unless independent (ev/chan 1)))
  (defer (do (when listener (ev/close listener) (set listener nil))
             (when admitted (ev/chan-close admitted)) (each peer (keys candidates) (ev/close peer)))
    (def packet (table ;(kvs request)))
    (put packet "version" p/version)
    (def token (unless independent (p/base64 (os/cryptorand 32))))
    (unless independent
      (put packet "port" ((net/localname listener) 1))
      (put packet "token" token)
      (put packet "quiet" (true? quiet)))

    (def output (if (or independent quiet)
                  (file/open (case (os/which) :windows "NUL" :mingw "NUL" "/dev/null") :wbn) stderr))
    (def process
      (defer (when (or independent quiet) (file/close output))
        (os/spawn (array/concat @[] launcher [main-script (if independent "independent" "worker")]
                    (map |(string (limits $)) ["frameBytes" "depth" "inFlight" "handles" "admissionSeconds"]))
                  :pd {:in :pipe :out (if independent :pipe output) :err output})))
    (def exited (future (fn []
      (defer (when listener (ev/close listener) (set listener nil)) (os/proc-wait process)))))

    (var stream nil)
    (try
      (do
        (defer (ev/close (process :in))
          (ev/with-deadline (limits "admissionSeconds")
            (p/send (process :in) packet)
            (if independent
              (do
                (set stream (process :out))
                (def ready (p/record (p/receive stream) ["version" "type"] []))
                (assert (and (= p/version (ready "version")) (= "ready" (ready "type"))) "InvalidProtocol"))
              (do
                (ev/spawn
                  (try
                    (net/accept-loop listener (fn [peer]
                      (if (or (nil? listener) (>= (length candidates) (limits "inFlight"))) (ev/close peer)
                        (do
                          (put candidates peer true)
                          (try
                            (do
                              (def proof (net/chunk peer (length token)))
                              (assert (and proof (= token (string proof))) "InvalidProtocol")
                              (ev/give admitted peer))
                            ([err] (put candidates peer nil) (ev/close peer)))))))
                    ([err] (ev/chan-close admitted))))
                (set stream (ev/take admitted))
                (assert stream "ProcessFailure")
                (put candidates stream nil)
                (ev/close listener)
                (set listener nil)
                # Only the private pipe can confirm the connection accepted by the real parent.
                (p/send (process :in) {"version" p/version "peer" (net/peername stream)})))))

        (if independent
          (future (fn []
            (defer (ev/close stream)
              (def terminal (p/event (p/receive stream)))
              (assert (and (index-of (terminal "type") ["result" "error"]) (not (p/receive stream))) "InvalidProtocol")
              (assert (= 0 (await exited)) "ProcessFailure")
              (if (= "result" (terminal "type")) (p/base64 (terminal "output") true) (error (terminal "message"))))))
          {:stream stream :exited exited}))
      ([err]
        (when stream (ev/close stream))
        (when independent (ev/close (process :out)))
        (error err)))))

(defn worker [request stream quiet]
  (def lock (ev/lock))
  (def replies @{})
  (def disconnected (ev/chan 1))
  (var sequence 0)
  (var closing false)
  (var failure "ControllerLost")
  (ev/spawn
    (defer (do (each channel (values replies) (ev/chan-close channel)) (table/clear replies) (ev/give disconnected true))
      (try
        (do
          (var reply nil)
          (while (set reply (p/receive stream))
            (p/event reply true)
            (assert (has-key? replies (reply "id")) "InvalidProtocol")
            (def channel (replies (reply "id")))
            (put replies (reply "id") nil)
            (ev/give channel reply)))
        ([err] (set failure err)))))

  (defn exchange [frame wait]
    (def channel (when wait (ev/chan 1)))
    (if (and quiet (not wait))
      (assert (<= (+ 9 (length (p/json (p/event frame)))) ((dyn :pa/limits) "frameBytes")) "TransportLimit")
      (ev/with-lock lock
        (assert (not closing) "ControllerLost")
        (var id nil)
        (when wait
          (assert (< (length replies) (+ ((dyn :pa/limits) "inFlight") ((dyn :pa/limits) "handles"))) "ResourceLimit")
          (set id (string (++ sequence)))
          (put frame "id" id)
          (put replies id channel))
        (try (p/send stream frame)
          ([err] (when id (put replies id nil)) (ev/close stream) (error err)))))
    (when wait
      (def reply (ev/take channel))
      (assert reply failure)
      (if (= "error" (reply "type")) (error (reply "message")) (reply "output"))))

  (def api
    {:imports (fn [] (tuple/slice (request "imports")))
     :import (fn [name]
               (assert (index-of name (request "imports")) "ImportNotGranted")
               (fn [input &named member]
                 (p/base64 (exchange (p/frame "import" "name" name "member" (or member "call") "input" (p/base64 input)) true) true)))
     :emit (fn [bytes &opt mode]
             (assert (index-of mode [nil :append]) "InvalidEmitMode")
             (exchange (p/frame (if mode "append" "emit") "output" (p/base64 bytes)) false) nil)
     :log (fn [stage] (exchange (p/frame "log" "stage" stage) false) nil)
     :spawn (fn [target input config &named imports member spawn]
              (assert (request "spawn") "SpawnNotGranted")
              (def token (exchange (p/frame "spawn" "name" target "input" (p/base64 input) "config" (p/base64 config)
                                           "imports" (or imports []) "member" (or member "call") "spawn" (or spawn false)) true))
              # Transfer once even when ignored; all program awaits share the decoded future.
              (future (fn [] (p/base64 (exchange (p/frame "await" "handle" token) true) true))))
     :await await})

  (try
    (do
      (def base (make-env))
      (each [k v] (pairs api) (put base (symbol "pa/" k) @{:value v :private true}))
      (put base :pa/limits (dyn :pa/limits))
      (put base *syspath* (os/realpath ((request "program") "sourceDir")))
      (each [name root] (pairs (get (request "program") "dependencies" {}))
        (put base (keyword name) (os/realpath root)))
      (put module/loaders :markdown md/load)
      (put base *module-make-env* (fn [] (make-env base)))
      (with-env base
        (module/add-paths ".md" :markdown)
        (module/add-file-extension ".md" :markdown)
        (def env (require (string (base *syspath*) "/" ((request "program") "entryModule"))))
        (def name (symbol (request "member")))
        (assert (has-key? env name) "UnknownMember")
        (assert (not ((env name) :macro)) "NotCallable")
        (def target (module/value env name))
        (assert (index-of (type target) [:function :cfunction]) "NotCallable")
        (def terminal (with-env env
          (p/frame "result" "output" (p/base64 (target (p/base64 (request "input") true) (p/base64 (request "config") true))))))
        (ev/with-lock lock (set closing true) (p/send stream terminal))))
    ([err fiber]
      (unless quiet
        (def trace @"")
        (def bound ((dyn :pa/limits) "frameBytes"))
        (with-dyns [:err (fn [bytes]
                          (buffer/push-string trace (string/slice bytes 0
                            (min (length bytes) (- bound (length trace))))))]
          (debug/stacktrace fiber))
        (exchange (p/diagnostic "traceback" (string trace)) false))
      (ev/with-lock lock (set closing true) (p/send stream (p/diagnostic "error" err)))))
  (net/shutdown stream :w)
  (ev/take disconnected))

(defn run [request sink &opt quiet]
  (p/request request)
  (def grants (table ;(catseq [grant :in (get request "imports" [])] [(grant "name") grant])))
  (def visible (get request "visible" (sorted (keys grants))))
  (def handles @{})
  (var requests 0)
  (var active 0)
  (var closing false)
  (def handle (launch {"program" (request "program") "input" (request "input") "config" (request "config")
                      "member" (get request "member" "call") "imports" (tuple/slice visible)
                      "spawn" (> (length (get request "spawn" [])) 0)} (get (request "program") "command" ["janet"]) false quiet))
  (def stream (handle :stream))
  (def lock (ev/lock))

  (def result
    (try
      (do
        (var terminal nil)
        (var frame nil)
        (while (set frame (p/receive stream))
          (def query frame)
          (assert (and (= p/version (query "version")) (not terminal)) "InvalidProtocol")
          (def kind (query "type"))
          (cond
            (index-of kind ["result" "error"]) (do
              (set terminal (p/event query))
              (ev/with-lock lock
                (set closing true)
                (try (net/shutdown stream :w) ([err] nil))))
            (index-of kind ["emit" "append" "log" "traceback"]) (do (p/event query) (unless quiet (sink query)))
            (index-of kind ["import" "spawn" "await"])
            (do
              (def fields (get {"import" ["name" "member" "input"]
                                "spawn" ["name" "member" "input" "config" "imports" "spawn"] "await" ["handle"]} kind))
              (p/record query (array/concat @["version" "type" "id"] fields) [])
              (def id (query "id"))
              (assert (= id (string (++ requests))) "InvalidProtocol")
              (def waiting (= kind "await"))
              (def child (when waiting (get handles (query "handle"))))
              (def rejection (cond (and waiting (not (table? child))) "UnknownHandle"
                                  (and (not waiting) (>= active ((dyn :pa/limits) "inFlight"))) "ResourceLimit"))
              (if rejection
                (ev/with-lock lock (p/send stream (p/diagnostic "error" rejection "id" id "code" rejection)))
                (do
                  (if waiting (put handles (query "handle") false) (++ active))
                  (ev/spawn
                    (defer (if waiting (put handles (query "handle") nil) (-- active))
                      (def reply
                        (try
                          (case kind
                            "import" (do
                              (assert (index-of (query "name") visible) "ImportNotGranted")
                              (def grant (grants (query "name")))
                              (assert (index-of (query "member") (grant "members")) "MemberNotGranted")
                              (def value (run {"version" p/version "program" (grant "program") "input" (query "input")
                                               "config" (grant "config") "member" (query "member") "imports" (values grants)
                                               "visible" (get grant "imports" [])
                                               "spawn" (if (get grant "spawn" false) (get request "spawn" []) [])}
                                              (fn [frame] (unless closing (sink frame))) quiet))
                              (if (= "error" (value "type"))
                                (p/diagnostic "error" (value "message") "id" id "code" (value "code"))
                                (p/frame "reply" "id" id "output" (value "output"))))
                            "spawn" (do
                              (assert (> (length (get request "spawn" [])) 0) "SpawnNotGranted")
                              (assert (< (length handles) ((dyn :pa/limits) "handles")) "ResourceLimit")
                              (assert (and (boolean? (query "spawn")) (indexed? (query "imports"))) "InvalidProtocol")
                              (def self (= "self" (query "name")))
                              (assert (or self (index-of (query "name") visible)) "ImportNotGranted")
                              (def grant (if self request (grants (query "name"))))
                              (unless self
                                (assert (index-of (query "member") (grant "members")) "MemberNotGranted")
                                (when (query "spawn") (assert (get grant "spawn" false) "SpawnNotGranted")))
                              (each name (query "imports")
                                (assert (and (in grants name)
                                             (index-of name (if self visible (get grant "imports" [])))) "ImportNotGranted"))
                              (put handles id false)
                              (def spawned (launch (p/request {"version" p/version "program" (grant "program")
                                "input" (query "input") "config" (if self (query "config") (grant "config"))
                                "member" (query "member") "imports" (values grants) "visible" (query "imports")
                                "spawn" (if (query "spawn") (request "spawn") [])}) (request "spawn") true))
                              (put handles id (unless closing spawned))
                              (p/frame "reply" "id" id "output" id))
                            "await" (p/frame "reply" "id" id "output" (p/base64 (await child))))
                          ([err]
                            (when (= kind "spawn") (put handles id nil))
                            (p/diagnostic "error" err "id" id))))
                      (try (ev/with-lock lock (unless closing (p/send stream reply)))
                           ([err] (ev/close stream))))))))
            (error "InvalidProtocol")))
        (if (and (= 0 (await (handle :exited))) terminal) terminal
          (p/frame "error" "code" "ProcessFailure" "message" "Program exited without a successful terminal frame")))
      ([err] (p/diagnostic "error" err))))

  (set closing true)
  (ev/close stream)
  (table/clear handles)
  result)

(defn- request [program input config options]
  {"version" p/version "program" program "input" (p/base64 input) "config" (p/base64 config)
   "member" (get options :member "call") "spawn" (get options :spawn [])
   "imports" (seq [grant :in (get options :imports [])]
                (merge grant {"config" (p/base64 (grant "config"))}))})

(defn invoke [program input config options]
  (with-dyns [:pa/limits (p/limits (options :limits))]
    (def result (run (request program input config options) (get options :sink (fn [&] nil))))
    (if (= "result" (result "type")) (p/base64 (result "output") true) (error (result "message")))))

(defn spawn [program input config options]
  (with-dyns [:pa/limits (p/limits (options :limits))]
    (def packet (p/request (request program input config options)))
    (assert (> (length (packet "spawn")) 0) "SpawnNotGranted")
    (launch packet (packet "spawn") true)))
