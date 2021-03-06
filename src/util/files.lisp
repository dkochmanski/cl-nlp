;;; (c) 2013 Vsevolod Dyomkin

(in-package #:nlp.util)
(named-readtables:in-readtable rutils-readtable)


(defun data-file (filename)
  "File in data/ subdir of cl-nlp."
  (asdf:system-relative-pathname 'cl-nlp
                                 (strcat "data/" filename)))

(defun model-file (filename)
  "File in models/ subdir of cl-nlp."
  (asdf:system-relative-pathname 'cl-nlp
                                 (strcat "models/" filename)))

(defun src-file (filename)
  "File in src/ subdir of cl-nlp."
  (asdf:system-relative-pathname 'cl-nlp
                                 (strcat "src/" filename)))

(defun corpus-file (filename)
  "File in corpora/ subdir of cl-nlp."
  (asdf:system-relative-pathname 'cl-nlp
                                 (strcat "corpora/" filename)))

(defun test-file (filename)
  "File in test/ subdir of cl-nlp."
  (asdf:system-relative-pathname 'cl-nlp
                                 (strcat "test/" filename)))

;;; writing

(defun write-bin-file (path data)
  "Save octet sequence DATA to file at PATH,
   overwriting it if it already exists."
  (with-open-file (out path
                       :direction :output :element-type 'unsigned-byte
                       :if-exists :supersede :if-does-not-exist :create)
    (write-sequence data out))
  path)

(defun write-dict (dict file &key (separator " "))
  "Dump DICT to a FILE with each key-value pair on a separate line
   separated by SEPARATOR."
  (with-out-file (out file)
    (dotable (k v dict)
      (format out "~A~A~A~%" k separator v))))

(defmacro with-tmp-file ((path contents) &body body)
  "Execute BODY inside a loop with a temporary text file having CONTENTS
   whose full path is bound to PATH."
  `(let ((,path (fmt "/tmp/cl-nlp-~A" (gensym))))
     (unwind-protect
          (progn (with-open-file (out ,path :direction :output
                                      :if-does-not-exist :create)
                   (princ ,contents out))
                 ,@body)
       (ignore-errors (delete-file ,path)))))

;;; reading

(defun list-from-file (file)
  "Load the contents of FILE into a list of strings for each trimmed line."
  (format *debug-io* "~&Reading list from file: ~A - " file)
  (let (rez)
    (dolines (line file)
      (push (string-trim +white-chars+ line) rez))
    (format *debug-io* "done.~%")
    (reverse rez)))

(defun dict-from-file (file &key (separator " ") (test 'equal)
                       (key-transform 'identity) (val-transform 'identity))
  "Read a dict with test predicate TEST from FILE,
   asssuming each key-value pair is on a separate line,
   key and value separated by SEPARATOR.
   If KEY-TRANSFORM and/or VAL-TRANSFORM are provided,
   they are applied before setting a respected value
   in the resulting hash-table.
   If the same key is read several times a warning will be sugnalled."
  (format *debug-io* "~&Reading dict from file: ~A - " file)
  (let ((dict (make-hash-table :test test)))
    (dolines (line file)
      (let* ((split-pos (search separator line))
             (k (funcall key-transform (slice line 0 split-pos)))
             (v (funcall val-transform (slice line (+ split-pos
                                                      (length separator))))))
        (when-it (get# k dict)
          (warn "Key: ~A has been already in dict with value: ~A. New value: ~A"
                k it v))
        (set# k dict v)))
    (format *debug-io* "done.~%")
    dict))


;;; walking

(defmacro dofiles ((file path &key ext (progress t)) &body body)
  "Iterate over all files in directory PATH,
   optionally matching extension EXT.
   If PROGESS is set, prints a dot for each file."
  (once-only (ext)
    `(fad:walk-directory ,path
                         (lambda (,file)
                           (when (or (null ,ext)
                                     (string= ,ext (pathname-type ,file)))
                             (princ "." *debug-io*)
                             (finish-output *debug-io*)
                             ,@body)))))


;;; downloading

(defgeneric download (what &key url dir)
  (:documentation
   "Download WHAT from URL to DIR."))

(defun download-file (url dir)
  "Download file from URL and place it into DIR by the name
   inferred from the URL, overwriting any existing file with the same name.
   Returns file path and filename."
  (let* ((real-uri (puri:uri-path (nth-value 3 (drakma:http-request
                                                url :method :head))))
         (filename (sub real-uri (1+ (position #\/ real-uri :from-end t))))
         (path (merge-pathnames filename dir)))
    (write-bin-file path (drakma:http-request url :force-binary t))
    (values path
            filename)))


;;; tsv

(defgeneric write-tsv (table &key keys cols cumulative order-by)
  (:documentation
   "Write a temporary tsv file from TABLE using either all
    or provided KEYS and COLS. Can use CUMULATIVE counts and ORDER-BY.

    The file contents look like this:

    No Label        Col1   Col2          Col3
    1  One          1      2             3
    2  Two          4      5             6
    ...

    Return the file name and number of keys and columns as other values."))


;;; zip

(defun zipped-file-data (zip name &key (encoding :utf-8))
  "Get the contents of a file NAME inside an open zip archive ZIP.
   If ENCODING is indicated (default - :UTF-8), decode raw data as encoded characters."
  (let ((raw (zip:zipfile-entry-contents (zip:get-zipfile-entry name zip))))
    (if encoding
        (babel:octets-to-string raw :encoding encoding)
        raw)))

(defun zip-add-text-file (zip name data)
  "Add DATA as a text file named NAME to the zip archive ZIP."
  (zip:write-zipentry zip name
                      (flex:make-in-memory-input-stream
                       (babel:string-to-octets data
                                               :encoding :utf-8))
                      :file-write-date (get-universal-time)))

(defmacro do-zip-entries ((name stream zip &key (external-format :utf-8) raw)
                          &body body)
  "An encoding-aware version of ZIP:DO-ZIPFILE-ENTRIES that provides access
   to the data stream."
  (with-gensyms (entry)
    `(zip:do-zipfile-entries (,name ,entry ,zip)
       (unless (char= #\/ (elt ,name (1- (length ,name))))
         ,(if raw
              `(flex:with-input-from-sequence
                   (,stream (zip:zipfile-entry-contents ,entry))
                 ,@body)
              `(with-input-from-string
                   (,stream (flex:octets-to-string
                             (zip:zipfile-entry-contents ,entry)
                             :external-format ,external-format))
                 ,@body))))))

(defmacro with-zip ((stream src &key (external-format :utf-8) raw) &body body)
  "Process contents in BODY of all files in zip archive at SRC
   binding them to a a string input STREAM.
   The archive's EXTERNAL-FORMAT may be specified.
   If RAW is T, will not decode the file's binary stream to string."
  (with-gensyms (zip name)
    `(zip:with-zipfile (,zip ,src)
       (do-zip-entries (,name ,stream ,zip
                              :external-format ,external-format :raw ,raw)
         ,@body))))

(defmacro with-zipped-zip ((name stream zipfile-entry
                                   &key (external-format :utf-8) raw)
                           &body body)
  "Like WITH-ZIP+DO-ZIPFILE-ENTRIES, but for processing
   embedded archive passed as ZIPFILE-ENTRY."
  (with-gensyms (zipstream v end entry entries zip x n)
    `(flex:with-input-from-sequence (,zipstream
                                     (zip:zipfile-entry-contents ,zipfile-entry))
       (let ((,v (make-array (zip:zipfile-entry-size ,zipfile-entry)
                             :element-type '(unsigned-byte 8))))
         (read-sequence ,v ,zipstream)
         (if-it (search #(80 75 5 6) ,v :from-end t)
                (file-position ,zipstream it)
                (error "end of central directory header not found"))
         (let* ((,end (zip::make-end-header ,zipstream))
                (,n (zip::end/total-files ,end))
                (,entries (make-hash-table :test #'equal))
                (,zip (zip::make-zipfile :stream ,zipstream
                                         :entries ,entries
                                         :external-format ,external-format)))
           (file-position ,zipstream (zip::end/central-directory-offset ,end))
           (dotimes (,x ,n)
             (let ((,entry (zip::read-entry-object ,zipstream ,external-format)))
               (set# (zip:zipfile-entry-name ,entry) ,entries ,entry)))
           (do-zip-entries (,name ,stream ,zip
                              :external-format ,external-format :raw ,raw)
             ,@body))))))
