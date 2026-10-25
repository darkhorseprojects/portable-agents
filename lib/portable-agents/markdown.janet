(def- markdown
  (delay
    (def api (require "remarkable/lib/remarkable"))
    [(module/value api 'parse-md)
     (peg/compile (module/value (require "remarkable/lib/blocks") 'grammar))
     (peg/compile (module/value (require "remarkable/lib/inlines") 'grammar))]))

(defn- content [node]
  (if (bytes? node) (string node)
    (let [[kind attrs children] node]
      (case kind
        :list (tuple/slice (map content children))
        :list-item (let [parts (tuple/slice (map content children))] (if (= 1 (length parts)) (first parts) {:content parts}))
        :blockquote {:content (tuple/slice (map content children))}
        :codeblock {:language (get attrs :info "") :text (string/join children)}
        :thematic-break "---"
        :hardbreak "\n"
        (let [body (if (bytes? children) (string children) (string/join (map content children)))]
          (if (index-of kind [:link :image]) (string body " (" (attrs :url) ")") body))))))

(defn load [path args]
  (def loading (dyn *module-loading* module/loading))
  (put loading path true)
  (defer (put loading path nil)
    (def [parse blocks inlines] (markdown))
    (def ast (parse (slurp path) :blocks blocks :inlines inlines))
    (def root @{:content @[]})
    (def stack @[[0 root]])
    (def code @"")
    (each node (ast 2)
      (def [kind attrs children] node)
      (cond
        (= kind :heading)
        (do
          (def level (attrs :level))
          (while (>= ((last stack) 0) level) (array/pop stack))
          (def section @{:name (content node) :level level :content @[]})
          (array/push (((last stack) 1) :content) section)
          (array/push stack [level section]))
        (and (= kind :codeblock) (= :fenced (attrs :kind)) (= "janet" (attrs :info)))
        (buffer/push-string code (string/join children) "\n")
        (array/push (((last stack) 1) :content) (content node))))
    (def document (postwalk |(cond (buffer? $) (string $) (array? $) (tuple/slice $)
                                  (table? $) (struct ;(mapcat identity (pairs $))) $) root))
    (def env ((dyn *module-make-env* make-env)))
    (put env 'document @{:value document})
    (with [file (file/temp)]
      (file/write file code)
      (file/seek file :set 0)
      (dofile file ;args :env env :source path))))

(defn register []
  (put module/loaders :markdown load)
  (module/add-paths ".md" :markdown)
  (module/add-file-extension ".md" :markdown))

(register)
