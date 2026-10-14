(import ../src/pa)

(defn echo [input config]
  (print "raw output")
  (pa/emit "observed")
  input)

(defn finish [input config]
  (pa/emit "accepted")
  (ev/sleep 0.3)
  (spit config input)
  input)

(defn nested [input config]
  (def child (pa/spawn (merge (dyn :pa/program) {"entry" "finish"}) input config {:limits (dyn :pa/limits)}))
  (assert (= (pa/await child) (pa/await child)) "completion changed")
  (pa/await child))
