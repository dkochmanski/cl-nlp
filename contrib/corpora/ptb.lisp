;;; (c) 2013-2015 Vsevolod Dyomkin

(in-package #:nlp.contrib.corpora)
(named-readtables:in-readtable rutils-readtable)


(defstruct (ptb-tagged-text (:include text))
  "A single text from the tagged section of the Penn Treebank corpus."
  nps)


(defmethod read-corpus-file ((type (eql :ptb-tagged)) file &key)
  (let ((*package* (find-package :tag))
        pars nps)
    (dolist (par (remove-if
                   #`(starts-with "*x*" %) ; remove headers from Brown corpus files
                   (mapcar (lambda (par)
                             (mapcar #`(strjoin #\Space %)
                                     par))
                           (mapcar #`(split-if #'blankp
                                               (split #\Newline %))
                                   (remove-if #'blankp
                                              (mapcar
                                               #`(string-trim +white-chars+ %)
                                               (re:split "={38}"
                                                         (read-file file))))))))
      (let (cur-par cur-par-nps)
        (dolist (sent par)
          ;; account for tokens that have square brackets in them 1/2
          (:= sent (re:regex-replace-all "(\\w)\\]" sent "\\1}}"))
          (let (cur-sent cur-nps)
            (dolist (phrs (split #\] sent :remove-empty-subseqs t))
              (let (cur-np)
                (dolist (tok (split #\Space phrs :remove-empty-subseqs t))
                  (unless (string= "[" tok)
                    ;; account for tokens that have square brackets in them 2/2
                    (:= tok (re:regex-replace-all "(\\w)}}" tok "\\1]"))
                    (:= tok (make-tagged-token tok))
                    (push tok cur-np)
                    (push tok cur-sent)))
                (push (reverse cur-np) cur-nps)))
            (push (reverse cur-nps) cur-par-nps)
            (push (reverse cur-sent) cur-par)))
        (push (reverse cur-par-nps) nps)
        (push (reverse cur-par) pars)))
    (reversef pars)
    (make-ptb-tagged-text :name (pathname-name file)
                          :clean (paragraphs->text pars)
                          :tokenized pars
                          :nps (reverse nps))))

(defmethod read-corpus ((type (eql :ptb-tagged)) path &key (ext "POS"))
  (let ((rez (make-corpus :desc "Penn Treebank Tagged")))
    (dofiles (file path :ext ext)
      (push (read-corpus-file :ptb-tagged path)
            (corpus-texts rez)))
    rez))

(defmethod map-corpus ((type (eql :ptb-tagged)) path fn &key (ext "POS"))
  (dofiles (file path :ext ext)
    (funcall fn (read-corpus-file :ptb-tagged path))))


;;; util

(defun make-tagged-token (str)
  (let ((/-pos (position #\/ str :from-end t)))
    (make-token :word (slice str 0 /-pos)
                :tag (mksym (slice str (1+ /-pos))))))
