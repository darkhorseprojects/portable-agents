(import ./protocol :as p)

(assert (>= (cmp (tuple/slice (map scan-number (take 2 (string/split "." janet/version)))) [1 42]) 0) "Janet 1.42+ required")

(defn await [handle]
  (ev/take (handle :done))
  (ev/chan-close (handle :done))
  (def [ok value] (handle :outcome))
  (if ok value (error value)))

(defn spawn [program input config options]
  (def limits (p/limits (options :limits)))
  (with-dyns [:pa/limits limits]
    (def request (p/request {"version" p/version "program" program "input" (p/base64 input)
                            "config" (p/base64 config) "observe" false}))
    (def process (os/spawn [(os/getenv "PA_EXECUTABLE") "spawn"
                           ;(map |(string (limits $)) ["frameBytes" "depth" "admissionSeconds"])]
                          :d {:in :pipe :out :pipe :err stderr}))
    (def exited (ev/chan))
    (ev/go (fn [] (os/proc-wait process)) nil exited)
    (def reader (p/reader (process :out)))
    (def handle @{:done (ev/chan 1)})
    (var admitted false)
    (defer (unless admitted (ev/close (process :out)))
      (defer (ev/close (process :in))
        (p/send (process :in) request))
      (ev/with-deadline (limits "admissionSeconds")
        (def ready (p/event (p/receive reader)))
        (assert (= "ready" (ready "type")) (get ready "message" "ProcessFailure")))
      (set admitted true)
      (ev/go (fn []
        (with-dyns [:pa/limits limits]
          (defer (ev/close (process :out))
            (put handle :outcome
                 (try
                   (do
                     (def terminal (p/event (p/receive reader)))
                     (assert (and (index-of (terminal "type") ["result" "error"])
                                  (not (p/receive reader))) "InvalidProtocol")
                     (ev/take exited)
                     (assert (= 0 (process :return-code)) "ProcessFailure")
                     (if (= "result" (terminal "type")) [true (p/base64 (terminal "output") true)]
                       [false (terminal "message")]))
                   ([err] [false err])))))) nil (handle :done))
      handle)))
