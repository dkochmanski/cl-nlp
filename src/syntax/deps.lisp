;;; (c) 2013-2014 Vsevolod Dyomkin

(in-package #:nlp.deps)
(named-readtables:in-readtable rutils-readtable)


(defun export-dep (str)
  "Intern and export DEP in package, then return it."
  (let ((dep (intern str)))
    (export dep)
    dep))

(defparameter *deps* (dict-from-file (src-file "syntax/deps.txt")
                                     :test 'eql
                                     :key-transform #'export-dep)
  "Dependency labels.")
