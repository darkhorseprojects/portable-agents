(import ./pa)
(import ./protocol :as p)

(defn main [_ command & args]
  (unless (and (index-of command ["call" "worker" "independent"]) (= (length args) 5))
    (eprint "usage: agent call FRAME-BYTES DEPTH IN-FLIGHT HANDLES ADMISSION-SECONDS")
    (os/exit 1))

  # An observer's broken pipe must not terminate accepted independent work.
  (unless (index-of (os/which) [:windows :mingw]) (os/sigaction :pipe (fn [])))
  (def limits (p/limits (table ;(interleave ["frameBytes" "depth" "inFlight" "handles" "admissionSeconds"] (map scan-number args)))))
  (with-dyns [:pa/limits limits]
    (if (= command "call")
      (p/send stdout (try (pa/run (p/receive stdin true) |(p/send stdout $ true))
                         ([err] (p/diagnostic "error" err))) true)
      (do
        (def request (p/receive stdin))
        (assert (= p/version (get request "version")) "InvalidProtocol")
        (if (= command "worker")
          (do
            (assert (and (int? (request "port")) (<= 1 (request "port") 65535)
                         (boolean? (request "quiet")) (= 32 (length (p/base64 (request "token") true)))) "InvalidProtocol")
            (var stream nil)
            (defer (when stream (ev/close stream))
              (ev/with-deadline (limits "admissionSeconds")
                (set stream (net/connect "127.0.0.1" (request "port")))
                (net/write stream (request "token"))
                (net/flush stream)
                (def binding (p/receive stdin))
                (p/record binding ["version" "peer"] [])
                (assert (and (= p/version (binding "version")) (indexed? (binding "peer"))
                             (= (tuple/slice (binding "peer")) (net/localname stream))) "InvalidProtocol"))
              (pa/worker request stream (request "quiet"))))
          (do
            # Ownership transfers before acknowledgment, which can be lost.
            (p/request request)
            (try (p/send stdout (p/frame "ready")) ([err] nil))
            (def result (try (pa/run request (fn [&] nil) true) ([err] (p/diagnostic "error" err))))
            (try (p/send stdout result) ([err] nil)))))))
  (os/exit 0))
