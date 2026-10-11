# Protocol fixture

```janet
(defn call [input config]
  (pa/emit input :append)
  input)

(defn pause [input config]
  (ev/sleep (if (= input "ignored") 2 0.1))
  input)

(defn spawn-test [input config]
  (def ignored (pa/spawn "self" "ignored" config :member "pause"))
  (def child (pa/spawn "self" input config :member "pause"))
  (assert (= (pa/await child) (pa/await child)))
  (pa/await child))
```
