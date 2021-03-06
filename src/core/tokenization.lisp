;;; (c) 2013-2015 Vsevolod Dyomkin

(in-package #:nlp.core)
(named-readtables:in-readtable rutils-readtable)


(defstruct (token (:print-object (lambda (token stream)
                                   (with-slots (id word tag beg end) token
                                       (format stream "<~A~@[/~A~]~@[:~A~]~@[ ~A~]>"
                                               word tag
                                               id
                                               (when beg
                                                 (if end
                                                     (fmt "~A..~A" beg end)
                                                     beg)))))))
  "A corpus token with id or postition and possibly tag.
   Also may contain word lemma."
  id
  beg
  end
  word
  lemma
  tag)

(defclass sentence ()
  ((tokens :initarg :tokens :accessor sent-tokens))
  (:documentation "Basically, a sentence is a list of tokens."))

(defgeneric tokenize (tokenizer string)
  (:documentation
   "Tokenize STRING with TOKENIZER. Outputs 2 values:

    - list of words
    - list of spans as beg-end pairs"))

;; (defgeneric stream-tokenize (tokenizer input output &optional span-output)
;;   (:documentation
;;    "Tokenize INPUT with TOKENIZER and writes to OUTPUT one word per line.
;;     Also can write to SPAN-OUTPUT beg-end cons pairs related to words.
;;
;;     Usage example:
;;
;;         (let ((pipe (make-two-way-stream
;;                       (make-input-string-stream) (make-output-string-stream))))
;;           (bt:make-thread #`(stream-tokenize *standard-input* pipe))
;;           (loop :for line := (read-line pipe nil) :while line :do
;;              (print line)))
;;    "))


(defclass tokenizer ()
  ()
  (:documentation
   "Base class for tokenizers."))

(defmethod tokenize :around ((tokenizer tokenizer) string)
  "Pre-split text into lines and tokenize each line separately."
  (let ((offset 0)
        words spans)
    (loop :for line :in (split #\Newline string) :do
       (mv-bind (ts ss) (call-next-method tokenizer line)
         (:= words (nconc words ts)
             spans (nconc spans (mapcar #`(pair (+ (lt %) offset)
                                                (+ (rt %) offset))
                                        ss)))
         (:+ offset (1+ (length line)))))
    (values words
            spans)))


;;; Word tokenization

(defclass regex-word-tokenizer (tokenizer)
  ((regex :accessor tokenizer-regex :initarg :regex
          :initform
          (re:create-scanner
           "\\w+|[!\"#$%&'*+,./:;<=>?@^`~…\\(\\)⟨⟩{}\\[\\|\\]‒–—―«»“”‘’¶-]")
          :documentation
          "A simpler variant would be [^\\s]+ —
           it doesn't split punctuation, yet sometimes it's desirable."))
  (:documentation
   "Regex-based word tokenizer."))

(defmethod tokenize ((tokenizer regex-word-tokenizer) string)
  (loop :for (beg end) :on (re:all-matches (tokenizer-regex tokenizer) string)
                       :by #'cddr
     :collect (slice string beg end) :into words
     :collect (pair beg end) :into spans
     :finally (return (values words
                              spans))))

(define-lazy-singleton word-chunker
    (make 'regex-word-tokenizer :regex (re:create-scanner "[^\\s]+"))
  "Dumb word tokenizer, that will not split punctuation from words.")

(define-lazy-singleton basic-word-tokenizer (make 'regex-word-tokenizer)
  "Basic word tokenizer.")


(defclass postprocessing-regex-word-tokenizer (regex-word-tokenizer)
  ((regex :accessor tokenizer-regex :initarg :regex
          :initform
          (re:create-scanner
           (strcat ;; urls
                   "\\w+://\\S+"
                   ;; decimals
                   "|[+-]?[0-9](?:[0-9,.]*[0-9])?"
                   ;; regular words
                   "|[\\w@](?:[\\w'’`@-][\\w']|[\\w'][\\w@'’`-])*[\\w']?"
                   ;; punctuation & special symbols
                   "|[\"#$%&*+,/:;<=>@^`~…\\(\\)⟨⟩{}\\[\\|\\]‒–—―«»“”‘’'¶]"
                   ;; closing punctuation
                   "|[.!?]+"
                   ;; multiple dashes
                   "|-+"))))
  (:documentation
   "Regex-based word tokenizer."))

(defparameter *2char-contractions-regex*
  (re:create-scanner
   "i['‘’`]m|(?:\\w)['‘’`]s|(?:i|you|s?he|we|they)['‘’`]d$"
   :case-insensitive-mode t)
  "Regex to find 2 character contractions: I'm, he/she/it's, 'd")

(defparameter *3char-contractions-regex*
  (re:create-scanner
   "(?:i|you|s?he|we|they)['‘’`](?:ll|[vr]e)|n['‘’`]t$"
   :case-insensitive-mode t)
  "Regex to find 3 character contractions: 'll, 're, 've, n't")

(defmethod tokenize :around ((tokenizer postprocessing-regex-word-tokenizer)
                             string)
  (mv-bind (ws ss) (call-next-method)
    (let (words spans skip)
      (loop :for wtail :on ws :for stail :on ss :do
         (if skip (void skip)
             (let ((cur (first wtail))
                   (cur-span (first stail))
                   (prev (first words))
                   (next (second wtail)))
               (macrolet ((push-contractions (char-length)
                            `(let* ((next cur-span)
                                    (split-pos (- (length cur) ,char-length))
                                    (split (- (rt next) ,char-length)))
                               (push (slice cur 0 split-pos) words)
                               (push (slice cur split-pos) words)
                               (push (pair (lt next) split) spans)
                               (push (pair split (rt next)) spans))))
                 (cond
                   ;; glue together abbreviations, decimals
                   ((and prev
                         (= (lt cur-span) (rt (first spans)))
                         (or (and (string= "." cur)
                                  next
                                  (not (open-quote-char-p (char next 0)))
                                  (alphanumericp (char prev (1- (length prev)))))
                             (and (ends-with "." prev)
                                  (alphanumericp (char cur 0)))
                             (and (every #`(char= #\' %) prev)
                                  (every #`(char= #\' %) cur))))
                    (:= (first words) (strcat prev cur)
                        (first spans) (pair (lt (first spans))
                                            (rt cur-span))))
                   ;; processing times (00:00)
                   ((and prev next
                         (string= ":" cur)
                         (digit-char-p (char prev (1- (length prev))))
                         (digit-char-p (char next 0)))
                    (:= (first words) (strcat prev cur next)
                        (first spans) (pair (lt (first spans))
                                            (rt (second stail)))
                        skip t))
                   ;; splitting posessives and contractions: I'm, 'd, 's
                   ((re:scan *2char-contractions-regex* cur)
                    (push-contractions 2))
                   ;; splitting contractions: 'll, 've, 're, n't
                   ((re:scan *3char-contractions-regex* cur)
                    (push-contractions 3))
                   ;; splitting trailing '
                   ((re:scan "\\w+'+$" cur)
                    (push-contractions (- (length cur)
                                          (position-if-not #`(eql #\' %)
                                                           cur :from-end t)
                                          1)))
                   ;; pass other tokens as is
                   (t (push cur words)
                      (push cur-span spans)))))))
      (values (reverse words)
              (reverse spans)))))

(define-lazy-singleton word-tokenizer
    (make 'postprocessing-regex-word-tokenizer)
  "Default word tokenizer.")


;; (defclass treebank-word-tokenizer (tokenizer)
;;   ()
;;   (:documentation
;;    "The Treebank tokenizer uses regular expressions to tokenize text
;;     as in Penn Treebank. It's a port of Robert MacIntyre's tokenizer
;;     (see: <http://www.cis.upenn.edu/~treebank/tokenizer.sed>).
;;     It assumes that the text has already been split into sentences.

;;     This tokenizer performs the following steps:

;;     - split standard contractions: don't -> do n't, they'll -> they 'll
;;     - treat most punctuation characters as separate tokens
;;     - split off commas and single quotes, when followed by whitespace
;;     - separate periods that appear at the end of line
;;    "))

;; (let ((contractions-regex
;;        (re:create-scanner (s+ "("
;;                               "([^' ])('[sS]|'[mM]|'[dD]|') "
;;                               "|"
;;                               "([^' ])('ll|'re|'ve|n't|) "
;;                               "|"
;;                               "\\b("
;;                               "(can)(not)"
;;                               "|(d)('ye)"
;;                               "|(gim)(me)"
;;                               "|(gon)(na)"
;;                               "|(got)(ta)"
;;                               "|(lem)(me)"
;;                               "|(wan)(na)"
;;                               "|(mor)('m)"
;;                               ")\\b"
;;                               "|"
;;                               " ('t)(is|was)\\b"
;;                               ")"
;;                           :case-insensitive-mode t))
;;       (contractions3-regex (re:create-scanner
;;                                               :case-insensitive-mode t)))
;; (defmethod tokenize ((tokenizer treebank-word-tokenizer) string)
;;   (re-setf string
;;            ;; starting quotes
;;            (re:regex-replace-all "^\"" "``")
;;            (re:regex-replace-all "(``)" " \\1 ")
;;            (re:regex-replace-all "([ (\[{<])\"" "\\1 `` ")
;;            (re:regex-replace-all "^\"" "``")
;;            (re:regex-replace-all "^\"" "``")
;;            ;; punctuation
;;            (re:regex-replace-all "([:,])([^\\d])" " \\1 \\2 ")
;;            (re:regex-replace-all "\\.\\.\\." " ... ")
;;            (re:regex-replace-all "[;@#$%&?!]" " \\0 ")
;;            (re:regex-replace-all "([^\\.])(\\.)([\]\)}>\"']*)\\s*$" "\\1 \\2\\3 ")
;;            (re:regex-replace-all "--" " \\0 ")
;;            (re:regex-replace-all "[\\]\\[\\(\\)\\{\\}\\<\\>]" " \\0 ")
;;            (strcat " " " ")
;;            ;; quotes
;;            (re:regex-replace-all "([^'])(') " "\\1 \\2 ")
;;            (re:regex-replace-all "\"" " '' ")
;;            (re:regex-replace-all "(\\S)(\\'\\')" "\\1 \\2 ")

;;            (re:regex-replace-all contractions-regex "\\1 \\2 ")
;;            (re:regex-replace-all " +" " ")
;;            (string-trim " "))
;;   (unless (blankp string)
;;     (setf text (strcat string " ")))
;;   (tokenize <word-chunker> string))

;;; Sentence splitting

(defclass baseline-sentence-tokenizer (tokenizer)
  ()
  (:documentation
   "Basic tokenizer for sentence splitting."))

(defvar +abbrevs-with-dot+
  (list-from-file (data-file "abbrevs-with-dot.txt"))
  "Widely-used abbreviations ending in dot.")

(defmethod tokenize ((tokenizer baseline-sentence-tokenizer) string)
  (mv-bind (words word-spans)
      (tokenize (make 'regex-word-tokenizer :regex "[^\\s]+")
                (substitute #\¶ #\Newline string))
    (let ((beg 0)
          sentences spans)
      (loop :for ws :on words :and ss :on word-spans :do
         (let ((word (first ws))
               (span (first ss)))
           (when (or (null (rest ws))
                     (and (member (char word (1- (length word)))
                                  '(#\. #\? #\! #\¶))
                          (not (member word +abbrevs-with-dot+
                                       :test #'string-equal))
                          (and-it (second ws)
                                  (upper-case-p (char it 0)))))
             (push (slice string beg (rt span)) sentences)
             (push (pair beg (rt span)) spans)
             (:= beg (lt (second ss))))))
      (values (reverse sentences)
              (reverse spans)))))

(define-lazy-singleton sentence-splitter (make 'baseline-sentence-tokenizer)
  "Basic sentence splitter.")


;;; Paragraph splitting

(defclass doublenewline-paragraph-splitter ()
  ()
  (:documentation
   "Paragraph tokenizer that splits text on double newlines
    and removes single newlines."))

(defmethod tokenize ((tokenizer doublenewline-paragraph-splitter) string)
  (let ((newline-regex (re:create-scanner (fmt "(?:~C|[~C~C]{1,2})"
                                               #\Newline #\Return #\Linefeed))))
    (mapcar #`(fmt "~{~A ~}" %)
            (split-sequence-if #'blankp
                               (re:split newline-regex string)
                               :remove-empty-subseqs t))))

(define-lazy-singleton paragraph-splitter
    (make 'doublenewline-paragraph-splitter)
  "Basic paragraph splitter.")


;;; Full text tokenization

(defclass full-text-tokenizer ()
  ()
  (:documentation
   "Text tokenizer that tokenizees raw text STR
    into a paragraph-sentence-token structure."))

(defmethod tokenize ((tokenizer full-text-tokenizer) string)
  (mapcar (lambda (par)
            (mapcar #`(mv-bind (words spans) (tokenize <word-tokenizer> %)
                        (loop :for word :in words
                           :for (beg end) :in spans
                           :collect (make-token :word word :beg beg :end end)))
                    (tokenize <sentence-splitter> par)))
          (split #\Newline string)))

(define-lazy-singleton full-text-tokenizer
    (make 'full-text-tokenizer)
  "Full text tokenizer.")

(defun paragraphs->text (paragraphs)
  "Get a text string corresponding to a list of lists of tokens PARAGRAPHS."
  (strjoin #\Newline
           (mapcar (lambda (par)
                     (strjoin #\Space
                              (mapcar (lambda (sent)
                                        (strjoin #\Space
                                                 (mapcar #'token-word
                                                         (if (listp sent)
                                                             sent
                                                             (sent-tokens sent)))))
                                      par)))
                   paragraphs)))


;;; Helpers

(defmacro re-setf (var &body body)
  "For each clause in BODY wrap it in `(setf var (clause arg1 var args))`."
  `(progn
     ,@(mapcar (lambda (clause)
                 `(setf ,var (,(first clause)
                               ,@(when-it (second clause) (list it))
                               ,var
                               ,@(when-it (second clause) (nthcdr 2 clause)))))
               body)))
