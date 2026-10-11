(def version 6)

(defn record [value required optional]
  (assert (dictionary? value) "InvalidProtocol")
  (each k required (assert (has-key? value k) "InvalidProtocol"))
  (each k (keys value) (assert (or (index-of k required) (index-of k optional)) "InvalidProtocol"))
  value)

(defn limits [value]
  (record value ["frameBytes" "depth" "inFlight" "handles" "admissionSeconds"] [])
  (each key ["frameBytes" "depth" "inFlight" "handles"]
    (def n (value key))
    (assert (and (int? n) (<= 1 n 0x7fffffff)) "InvalidLimits"))
  (assert (and (>= (value "depth") 2) (number? (value "admissionSeconds"))
               (< 0 (value "admissionSeconds") math/inf)) "InvalidLimits")
  value)

(defn- program [value]
  (record value ["sourceDir" "entryModule"] ["dependencies" "command"])
  (when (has-key? value "command")
    (assert (and (indexed? (value "command")) (> (length (value "command")) 0)
      (every? (map |(and (string? $) (not= "" $) (not (string/find "\0" $))) (value "command")))) "InvalidProgram"))
  (each k ["sourceDir" "entryModule"]
    (assert (and (string? (value k)) (> (length (value k)) 0) (not (string/find "\0" (value k)))) "InvalidProgram"))
  (def dependencies (get value "dependencies" {}))
  (assert (dictionary? dependencies) "InvalidProgram")
  (each [prefix path] (pairs dependencies)
    (assert (and (string? prefix) (not= "" prefix) (not (string/find "/" prefix)) (not (string/find "\0" prefix))
                 (string? path) (> (length path) 0) (not (string/find "\0" path))) "InvalidProgram"))
  value)

(def- alphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
(def- indices (table ;(catseq [i :range [0 64]] [(alphabet i) i])))
(def- base64-shape (peg/compile ~(* (any (repeat 4 (set ,alphabet)))
                                  (opt (choice (* (repeat 2 (set ,alphabet)) (set "AEIMQUYcgkosw048") "=")
                                               (* (set ,alphabet) (set "AQgw") "=="))) -1)))

(defn base64 [bytes &opt decode]
  (def bound ((dyn :pa/limits) "frameBytes"))
  (assert (and (index-of (type bytes) [:string :buffer]) (<= (length bytes) bound)) "InvalidBytes")
  (when decode (assert (peg/match base64-shape bytes) "InvalidBase64"))
  (if (= decode :check) bytes
    (do
      (unless decode (assert (<= (* 4 (math/ceil (/ (length bytes) 3))) bound) "TransportLimit"))
      (def out @"")
      (def step (if decode 4 3))
      (for i 0 (math/ceil (/ (length bytes) step))
        (def offset (* i step))
        (if decode
          (do
            (var value 0)
            (for j 0 4 (def c (bytes (+ offset j))) (set value (+ (* value 64) (if (= c 61) 0 (indices c)))))
            (buffer/push-byte out (band 255 (brshift value 16)))
            (unless (= 61 (bytes (+ offset 2))) (buffer/push-byte out (band 255 (brshift value 8))))
            (unless (= 61 (bytes (+ offset 3))) (buffer/push-byte out (band 255 value))))
          (do
            (def value (+ (* 65536 (get bytes offset 0)) (* 256 (get bytes (+ offset 1) 0)) (get bytes (+ offset 2) 0)))
            (each shift [18 12 6 0]
              (buffer/push-byte out (if (< (+ offset (case shift 6 1 0 2 0)) (length bytes))
                                      (alphabet (band 63 (brshift value shift))) 61))))))
      (string out))))

(defn request [value]
  (record value ["version" "program" "input" "config"] ["imports" "visible" "member" "spawn"])
  (assert (= version (value "version")) "InvalidProtocol")
  (program (value "program"))
  (base64 (value "input") :check)
  (base64 (value "config") :check)
  (def launcher (get value "spawn" []))
  (assert (and (indexed? launcher) (every? (map |(and (string? $) (not= "" $) (not (string/find "\0" $))) launcher))) "InvalidSpawnGrant")
  (def member (get value "member" "call"))
  (assert (and (string? member) (not= "" member) (not (string/find "\0" member))) "InvalidMember")

  (def names @{})
  (assert (indexed? (get value "imports" [])) "InvalidProtocol")
  (each grant (get value "imports" [])
    (record grant ["name" "program" "config" "members"] ["imports" "spawn"])
    (assert (and (indexed? (grant "members")) (> (length (grant "members")) 0)
      (every? (map |(and (string? $) (not= "" $)) (grant "members")))) "InvalidImport")
    (assert (and (indexed? (get grant "imports" []))
      (boolean? (get grant "spawn" false))) "InvalidImport")
    (def name (grant "name"))
    (assert (and (string? name) (not= "" name) (not= "self" name) (not (string/find "\0" name)) (not (in names name))) "InvalidImport")
    (put names name true)
    (program (grant "program"))
    (base64 (grant "config") :check))

  (each grant (get value "imports" [])
    (each name (get grant "imports" [])
      (assert (has-key? names name) "InvalidImport")))
  (when (has-key? value "visible")
    (assert (indexed? (value "visible")) "InvalidImport")
    (each name (value "visible") (assert (has-key? names name) "ImportNotGranted")))

  value)

(def- utf8-unit ~(choice (range "\x00\x7f")
                        (* (range "\xc2\xdf") (range "\x80\xbf"))
                        (* "\xe0" (range "\xa0\xbf") (range "\x80\xbf"))
                        (* (range "\xe1\xec" "\xee\xef") (repeat 2 (range "\x80\xbf")))
                        (* "\xed" (range "\x80\x9f") (range "\x80\xbf"))
                        (* "\xf0" (range "\x90\xbf") (repeat 2 (range "\x80\xbf")))
                        (* (range "\xf1\xf3") (repeat 3 (range "\x80\xbf")))
                        (* "\xf4" (range "\x80\x8f") (repeat 2 (range "\x80\xbf")))))
(def- utf8 (peg/compile ~(* (any ,utf8-unit) -1)))
(def- utf8-prefix (peg/compile ~(capture (any ,utf8-unit))))
(def- escaping (peg/compile ~(choice (set "\"\\") (range "\x00\x1f"))))

(def- grammar (peg/compile
  ~{:main (* :ws :value :ws -1) :ws (any (set " \t\r\n"))
    :hex (set "0123456789abcdefABCDEF")
    :value (choice :object :array :str :num (replace "true" true) (replace "false" false) (replace "null" :json-null))
    :str (accumulate (* "\"" (any (choice (capture (some (* (not (choice (set "\"\\") (range "\x00\x1f"))) 1)))
                                        :escape :unicode)) "\""))
    :escape (* "\\" (/ (capture (set "\"\\/bfnrt"))
                         {"\"" "\"" "\\" "\\" "/" "/" "b" "\b" "f" "\f" "n" "\n" "r" "\r" "t" "\t"}))
    :unicode (/ (group (* "\\u" (choice
      (* (number (* (set "dD") (set "89aAbB") (repeat 2 :hex)) 16) "\\u"
         (number (* (set "dD") (set "cCdDeEfF") (repeat 2 :hex)) 16))
      (number (repeat 4 :hex) 16))))
      ,(fn [parts]
         (def point (if (= 2 (length parts)) (+ 0x10000 (* 1024 (- (parts 0) 0xd800)) (- (parts 1) 0xdc00)) (parts 0)))
         (assert (not (<= 0xd800 point 0xdfff)) "InvalidJson")
         (parse (string/format "\"\\U%06x\"" point))))
    :num (/ (capture (* (opt "-") (choice "0" (* (range "19") (any (range "09"))))
                        (opt (* "." (some (range "09")))) (opt (* (set "eE") (opt (set "+-")) (some (range "09"))))))
            ,(fn [s] (def n (scan-number s)) (assert (and n (< (math/abs n) math/inf)) "InvalidJson") n))
    :array (group (* "[" :ws (opt (* :value (any (* :ws "," :ws :value)))) :ws "]"))
    :object (/ (group (* "{" :ws (opt (* :str :ws ":" :ws :value (any (* :ws "," :ws :str :ws ":" :ws :value)))) :ws "}"))
               ,(fn [xs]
                  (def obj @{})
                  (loop [i :range [0 (length xs) 2]]
                    (def k (xs i))
                    (assert (not (has-key? obj k)) "DuplicateJsonKey")
                    (put obj k (xs (+ i 1))))
                  obj))}))

(defn json [value &opt decode]
  (def bound ((dyn :pa/limits) "frameBytes"))
  (def depth-limit ((dyn :pa/limits) "depth"))
  (if decode
    (do
      (assert (and (bytes? value) (<= (length value) bound) (peg/match utf8 value)) "InvalidJson")
      (var nesting 0)
      (var quoted false)
      (var escaped false)
      (each c value
        (cond escaped (set escaped false)
          (and quoted (= c 92)) (set escaped true)
          (= c 34) (set quoted (not quoted))
          (not quoted) (do
                         (when (index-of c [91 123]) (++ nesting))
                         (when (index-of c [93 125]) (-- nesting))
                         (assert (<= 0 nesting depth-limit) "TransportLimit"))))
      (def result (peg/match grammar value))
      (assert (= 1 (length (or result []))) "InvalidJson")
      (result 0))
    (do
      (var remaining bound)
      (defn encode [x depth]
        (assert (and (> remaining 0) (or (not (or (indexed? x) (dictionary? x))) (< depth depth-limit))) "TransportLimit")
        (-- remaining)
        (cond
          (nil? x) "null" (boolean? x) (if x "true" "false")
          (number? x) (do (assert (< (math/abs x) math/inf) "InvalidJson") (string/format "%.17g" x))
          (string? x) (do
            (assert (and (<= (length x) remaining) (peg/match utf8 x)) "InvalidJson")
            (-= remaining (length x))
            (string "\"" (peg/replace-all escaping
              (fn [s] (case (s 0) 34 "\\\"" 92 "\\\\" (string/format "\\u%04x" (s 0)))) x) "\""))
          (indexed? x) (string "[" (string/join (map |(encode $ (+ depth 1)) x) ",") "]")
          (dictionary? x) (string "{" (string/join (seq [k :keys x]
            (assert (string? k) "InvalidJson") (string (encode k (+ depth 1)) ":" (encode (x k) (+ depth 1)))) ",") "}")
          (error "InvalidJson")))
      (def out (encode value 0))
      (assert (<= (length out) bound) "TransportLimit")
      out)))

(defn frame [type & pairs] (table "version" version "type" type ;pairs))

(defn event [value &opt rpc]
  (def fields (get (if rpc {"reply" ["id" "output"] "error" ["id" "code" "message"]}
    {"emit" ["output"] "append" ["output"] "result" ["output"] "log" ["stage"] "traceback" ["message"] "error" ["code" "message"]}) (get value "type")))
  (assert fields "InvalidProtocol")
  (record value (array/concat @["version" "type"] fields) [])
  (assert (= version (value "version")) "InvalidProtocol")
  (each key fields (assert (string? (value key)) "InvalidProtocol"))
  (when (and (not rpc) (has-key? value "output")) (base64 (value "output") :check))
  value)

(def- header-shape (peg/compile ~(* (repeat 8 (set "0123456789abcdef")) ":" -1)))

(defn send [io value &opt ndjson]
  (def bytes (json (if ndjson (event value) value)))
  (assert (<= (+ (length bytes) (if ndjson 2 9)) ((dyn :pa/limits) "frameBytes")) "TransportLimit")
  # ASCII headers and escaped control bytes survive Windows text-mode stdio.
  (:write io (if ndjson (string bytes "\n") (string (string/format "%08x:" (length bytes)) bytes)))
  (when (get io :flush) (:flush io)))

(defn receive [io &opt ndjson]
  (def reader (if (get io :chunk) :chunk :read))
  (def bound ((dyn :pa/limits) "frameBytes"))
  (def header (reader io (if ndjson bound 9)))
  (if ndjson
    (do
      (assert (and header (= 10 (last header)) (= (- (length header) 1) (string/find "\n" header))
                   (not (reader io 1))) "InvalidProtocol")
      (json header true))
    (when header
      (assert (peg/match header-shape header) "InvalidProtocol")
      (def n (scan-number (string/slice header 0 8) 16))
      (assert (<= 1 n (- bound 9)) "TransportLimit")
      (def bytes (reader io n))
      (assert (and bytes (= n (length bytes))) "InvalidProtocol")
      (json bytes true))))

(defn diagnostic [type err & fields]
  (def result (frame type "message" "" ;fields))
  (when (and (= type "error") (not (has-key? result "code")))
    (put result "code" (if (= err "ResourceLimit") err "ProgramError")))
  (var budget (- ((dyn :pa/limits) "frameBytes") 9 (length (json result))))
  (def out @"")
  (each c (if (string? err) err "Program failed")
    (def cost (case c 34 2 92 2 (if (< c 32) 6 1)))
    (when (> cost budget) (break))
    (buffer/push-byte out c)
    (-= budget cost))
  (put result "message" ((peg/match utf8-prefix out) 0))
  result)
