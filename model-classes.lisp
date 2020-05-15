;;; Copyright 2012-2020 Google LLC
;;;
;;; Use of this source code is governed by an MIT-style
;;; license that can be found in the LICENSE file or at
;;; https://opensource.org/licenses/MIT.

(in-package "PROTO-IMPL")


;;; Protocol buffers model classes

(defvar *all-schemas* (make-hash-table :test #'equal)
  "A global table mapping names to 'protobuf-schema' objects.")

(defun find-schema (name)
  "Find a protobuf-schema for the given name. Returns nil if non exist.
Parameters:
  NAME: A string, symbol, or pathname."
  (values (gethash name *all-schemas*)))

;; Type for structure messages.
(defstruct base-message
  "Base structure that all protobuf message structs inherit from.")

;;; "Thread-local" variables

;; Parsing (and even pretty printing schemas) want to keep track of the current schema
(defvar *protobuf* nil
  "Bound to the Protobufs object currently being defined, either a schema or a message.")

(defvar *protobuf-package* nil
  "Bound to the Lisp package in which the Protobufs schema is being defined.")

(defvar *protobuf-rpc-package* nil
  "Bound to the Lisp package in which the Protobufs schema's service definitions are being defined.")

(defvar *protobuf-conc-name* nil
  "Bound to a conc-name to use for all the messages in the schema being defined.
   This controls the name of the accessors the fields of each message.
   When it's nil, there is no \"global\" conc-name.
   When it's t, each message will use the message name as the conc-name.
   When it's a string, that string will be used as the conc-name for each message.
   'parse-schema-from-file' defaults conc-name to \"\", meaning that each field in
   every message has an accessor whose name is the name of the field.")

(defvar *protobuf-pathname* nil
  "Bound to he name of the file from where the .proto file is being parsed.")

(defvar *protobuf-search-path* ()
  "Bound to the search-path to use to resolve any relative pathnames.")

(defvar *protobuf-output-path* ()
  "Bound to the path to use to direct output during imports, etc.")


;;; The model classes

(defclass abstract-protobuf () ())

;; It would be nice if most of the slots had only reader functions, but
;; that makes writing the Protobufs parser a good deal more complicated.
;; Too bad Common Lisp exports '(setf foo)' when you only want to export 'foo'
(defclass base-protobuf (abstract-protobuf)
  ((class :type (or null symbol)                ;the Lisp name for this object
          :accessor proto-class                 ;this often names a type or class
          :initarg :class
          :initform nil)
   (name :type (or null string)                 ;the Protobufs name for this enum, message, etc
         :reader proto-name
         :initarg :name
         :initform nil)
   (qual-name :type string                      ;the fully qualified name, e.g., "proto2.MessageSet"
              :accessor proto-qualified-name
              :initarg :qualified-name
              :initform "")
   (parent :type (or null base-protobuf)        ;this object's parent
           :accessor proto-parent
           :initarg :parent)
   (options :type (list-of protobuf-option)     ;options, mostly just passed along
            :accessor proto-options
            :initarg :options
            :initform ())
   (doc :type (or null string)                  ;documentation for this object
        :accessor proto-documentation
        :initarg :documentation
        :initform nil)
   (location :accessor proto-source-location    ;a list of (pathname start-pos end-pos)
             :initarg :source-location
             :initform nil))
  (:documentation
   "The base class for all Protobufs model classes."))

(defstruct proto-base
  "Base structure for protobuf meta-objects."
  (index nil :type (signed-byte 32)))

;; todo: Remove this temporary override.
(defmethod proto-index ((proto-message proto-base))
  (proto-base-index proto-message))

(defun find-qualified-name (name protos
                            &key (proto-key #'proto-name) (full-key #'proto-qualified-name)
                                 relative-to)
  "Find something by its string name, first doing a simple name match,
   and, if that fails, exhaustively searching qualified names."
  (declare (ignore relative-to))
  (or (find name protos :key proto-key :test #'string=)
      ;;--- This needs more sophisticated search, e.g., relative to current namespace
      (find name protos :key full-key  :test #'string=)))


;; A Protobufs schema, corresponds to one .proto file
(defclass protobuf-schema (base-protobuf)
  ((syntax :type (or null string)               ;syntax, passed on but otherwise ignored
           :accessor proto-syntax
           :initarg :syntax
           :initform "proto2")
   (package :type (or null string)              ;the Protobufs package
            :accessor proto-package
            :initarg :package
            :initform nil)
   (lisp-pkg :type (or null string)             ;the Lisp package, from 'option lisp_package = ...'
             :accessor proto-lisp-package
             :initarg :lisp-package
             :initform nil)
   ;; LISP-PKG may be NIL when it's not specified or may not be a valid package name if that package
   ;; is not found.  In that case, the current package is used instead.  REAL-LISP-PKG stores the
   ;; package that's actually used.
   (real-lisp-pkg :type (or null package)       ;actual lisp package
                  :accessor proto-real-lisp-package
                  :initarg :real-lisp-package
                  :initform nil)
   (alias-packages :type list                   ;list of (non-proto) packages forward referenced
                                                ;by aliases in this schema
               :accessor proto-alias-packages
               :initform nil)
   (imports :type (list-of string)              ;the names of schemas to be imported
            :accessor proto-imports
            :initarg :imports
            :initform ())
   (schemas :type (list-of protobuf-schema)     ;the schemas that were successfully imported
            :accessor proto-imported-schemas    ;this gets used for chasing namespaces
            :initform ())
   (services :type (list-of protobuf-service)
             :accessor proto-services
             :initarg :services
             :initform ()))
  (:documentation
   "The model class that represents a Protobufs schema, i.e., one .proto file."))

(defmethod make-load-form ((s protobuf-schema) &optional environment)
  (with-slots (class) s
    (multiple-value-bind (constructor initializer)
        (make-load-form-saving-slots s :environment environment)
      (values `(or (gethash ',class *all-schemas*) ,constructor)
              `(unless (gethash ',class *all-schemas*)
                 (record-schema ,s :symbol ',class)
                 ,initializer)))))

(defun record-schema (schema &key symbol)
  "Record all the names by which the Protobufs schema might be known.
Parameters:
  SCHEMA: The schema to record.
  SYMBOL: The symbol to map from in *all-schemas*."
  (let ((symbol (or symbol (proto-class schema))))
    (when symbol
      (setf (gethash symbol *all-schemas*) schema))
    (let ((pathname
           (or *protobuf-pathname*
               ;; Try to find the pathname under which a schema matching on CLASS
               ;; was previously recorded. Remap that pathname onto this schema.
               (block nil
                 (maphash (lambda (key existing-schema)
                            (when (and (pathnamep key) (eq (proto-class existing-schema) symbol))
                              (return key)))
                          *all-schemas*)))))
      (when pathname
        ;; Record the file from which the Protobufs schema came
        (setf (gethash pathname *all-schemas*) schema)))))

(defmethod print-object ((s protobuf-schema) stream)
  (if *print-escape*
    (print-unreadable-object (s stream :type t :identity t)
      (format stream "~@[~S~]~@[ (package ~A)~]"
              (and (slot-boundp s 'class) (proto-class s)) (proto-package s)))
    (format stream "~S" (and (slot-boundp s 'class) (proto-class s)))))

(defgeneric make-qualified-name (proto name)
  (:documentation
   "Give a schema or message and a name,
    generate a fully qualified name string for the name."))

(defmethod make-qualified-name ((schema protobuf-schema) name)
  ;; If we're at the schema, the qualified name is the schema's
  ;; package "dot" the name
  (if (proto-package schema)
    (strcat (proto-package schema) "." name)
    name))

;; find-* functions for finding different proto meta-objects

(defvar *type-aliases* (make-hash-table :test 'eq)
  "Maps alias names (symbols) to protobuf-type-alias instances.")

(declaim (inline find-type-alias))
(defun find-type-alias (alias)
  "Return the protobuf-type-alias instance named by ALIAS (a symbol)."
  (gethash alias *type-aliases*))

(defvar *messages* (make-hash-table :test 'eq)
  "Map from the protobuf message or schema symbol to the protobuf-message
class metaobject. If there is an 'extends' instance this will
be the last (largest) defined extended version of the protobuf-message
meta-object.")

(declaim (inline find-message))
(defun find-message (type)
  "Return the protobuf-message instance either named by TYPE (a symbol)
or thats named by the class-name of TYPE."
  (gethash (if (typep type 'standard-object)
               (class-name type)
               type)
           *messages*))

;; Do not use in production at run time.
(defun find-message-with-string (message name)
  "Return the protobuf-message instance in the package of
MESSAGE named by NAME (a string)."
  (declare (type string name))
  (find-message (intern (uncamel-case name)
                        (symbol-package (proto-class message)))))

(defun find-message-for-class (class)
  "Find a message for class.
Parameters:
  CLASS: Either a symbol naming the class or a class."
  (let* ((type (if (typep class 'symbol)
                   class
                   (class-name class))))
    (or (find-message type)
        (find-type-alias type))))

(defvar *enums* (make-hash-table :test 'eq)
  "Maps enum names (symbols) to protobuf-enum instances.")

(declaim (inline find-enum))
(defun find-enum (type)
  "Return a protobuf-enum instance named by TYPE (a symbol)."
  (gethash type *enums*))

(defgeneric find-service (protobuf name)
  (:documentation
   "Given a Protobufs schema,returns the Protobufs service of the given name."))

(defmethod find-service ((schema protobuf-schema) (name symbol))
  (find name (proto-services schema) :key #'proto-class))

(defmethod find-service ((schema protobuf-schema) (name string))
  (find-qualified-name name (proto-services schema)))

;; Convenience function that accepts a schema name
(defmethod find-service (schema-name name)
  (let ((schema (find-schema schema-name)))
    (assert schema ()
            "There is no schema named ~A" schema-name)
    (find-service schema name)))

;; We accept and store any option, but only act on a few: default, packed,
;; optimize_for, lisp_package, lisp_name, lisp_alias
(defclass protobuf-option (abstract-protobuf)
  ((name :type string                           ;the key
         :reader proto-name
         :initarg :name)
   (value :accessor proto-value                 ;the (untyped) value
          :initarg :value
          :initform nil)
   (type :type (or null symbol)                 ;(optional) Lisp type,
         :reader proto-type                     ;  one of string, integer, float, symbol (for now)
         :initarg :type
         :initform 'string))
  (:documentation
   "The model class that represents a Protobufs options, i.e., a keyword/value pair."))

(defmethod make-load-form ((o protobuf-option) &optional environment)
  (make-load-form-saving-slots o :environment environment))

(defmethod print-object ((o protobuf-option) stream)
  (if *print-escape*
    (print-unreadable-object (o stream :type t :identity t)
      (format stream "~A~@[ = ~S~]" (proto-name o) (proto-value o)))
    (format stream "~A" (proto-name o))))

(defun make-option (name value &optional (type 'string))
  (check-type name string)
  (make-instance 'protobuf-option
    :name name :value value :type type))

(defgeneric find-option (protobuf name)
  (:documentation
   "Given a Protobufs schema, message, enum, etc and the name of an option,
    returns the value of the option and its (Lisp) type. The third value is
    true if an option was found, otherwise it is false."))

(defmethod find-option ((protobuf base-protobuf) (name string))
  (let ((option (find name (proto-options protobuf) :key #'proto-name :test #'option-name=)))
    (when option
      (values (proto-value option) (proto-type option) t))))

(defmethod find-option ((options list) (name string))
  (let ((option (find name options :key #'proto-name :test #'option-name=)))
    (when option
      (values (proto-value option) (proto-type option) t))))

(defgeneric add-option (protobuf name value &optional type)
  (:documentation
   "Given a Protobufs schema, message, enum, etc
    add the option called 'name' with the value 'value' and type 'type'.
    If the option was previoously present, it is replaced."))

(defmethod add-option ((protobuf base-protobuf) (name string) value &optional (type 'string))
  (let ((option (find name (proto-options protobuf) :key #'proto-name :test #'option-name=)))
    (if option
      ;; This side-effects the old option
      (setf (proto-value option) value
            (proto-type option)  type)
      ;; This side-effects 'proto-options'
      (setf (proto-options protobuf)
            (append (proto-options protobuf)
                    (list (make-option name value type)))))))

(defmethod add-option ((options list) (name string) value &optional (type 'string))
  (let ((option (find name options :key #'proto-name :test #'option-name=)))
    (append (remove option options)
            (list (make-option name value type)))))

(defgeneric remove-options (protobuf &rest names)
  (:documentation
   "Given a Protobufs schema, message, enum, etc and a set of option names,
    remove all of those options from the set of options."))

(defmethod remove-options ((protobuf base-protobuf) &rest names)
  (dolist (name names (proto-options protobuf))
    (let ((option (find name (proto-options protobuf) :key #'proto-name :test #'option-name=)))
      (when option
        ;; This side-effects 'proto-options'
        (setf (proto-options protobuf) (remove option (proto-options protobuf)))))))

(defmethod remove-options ((options list) &rest names)
  (dolist (name names options)
    (let ((option (find name options :key #'proto-name :test #'option-name=)))
      (when option
        ;; This does not side-effect the list of options
        (setq options (remove option options))))))

(defun option-name= (name1 name2)
  (let* ((name1  (string name1))
         (name2  (string name2))
         (start1 (if (eql (char name1 0) #\() 1 0))
         (start2 (if (eql (char name2 0) #\() 1 0))
         (end1   (if (eql (char name1 0) #\() (- (length name1) 1) (length name1)))
         (end2   (if (eql (char name2 0) #\() (- (length name2) 1) (length name2))))
    (string= name1 name2 :start1 start1 :end1 end1 :start2 start2 :end2 end2)))


;; A Protobufs enumeration
(defstruct protobuf-enum
  "The meta-object for a protobuf-enum"
  (class nil :type (or null symbol))
  (name nil :type (or null string))
  (alias-for nil :type (list-of protobuf-enum-value))           ; the numeric value of the enum
  (values nil :type (list-of protobuf-enum-value)))           ; the Lisp value of the enum

(defmethod make-load-form ((e protobuf-enum) &optional environment)
  (make-load-form-saving-slots e :environment environment))

(defmethod make-qualified-name ((enum protobuf-enum) name)
  ;; The qualified name is the enum name "dot" the name
  (let ((qual-name (strcat (proto-name enum) "." name)))
    (if (proto-parent enum)
      ;; If there's a parent for this enum (either a message or
      ;; the schema), prepend the name (or package) of the parent
      (make-qualified-name (proto-parent enum) qual-name)
      ;; Guard against a message in the middle of nowhere
      qual-name)))


;; A Protobufs value within an enumeration
(defstruct (protobuf-enum-value (:include proto-base))
  "The model class that represents a Protobufs enumeration value."
  (value nil :type (or null symbol)))           ; the Lisp value of the enum

(defmethod make-load-form ((v protobuf-enum-value) &optional environment)
  (make-load-form-saving-slots v :environment environment))

;; An object describing a Protobufs message. Confusingly most local variables that hold
;; instances of this struct are named MESSAGE, but the C API makes it clear that
;; a Message is not its descriptor.
;; This would have been far less confusing if it sounded more obviously like a 'descriptor'
;; and not the contents of the message per se.
(defclass protobuf-message (base-protobuf)
  ((conc :type (or null string)                 ;the conc-name used for Lisp accessors
         :accessor proto-conc-name
         :initarg :conc-name
         :initform nil)
   (alias :type (or null symbol)                ;use this if you want to make this message
          :accessor proto-alias-for             ;  be an alias for an existing Lisp class
          :initarg :alias-for
          :initform nil)
   (fields :type (list-of protobuf-field)       ;all the fields of this message
           :accessor proto-fields               ;this includes local ones and extended ones
           :initarg :fields
           :initform ())
   (field-vect :type vector
               ;; The FIELDS slot (more or less) as a vector. If the index space is dense,
               ;; the vector is accessed by field index, otherwise it requires linear scan.
               ;; todo: sparse indices can do better than linear scan.
               :accessor proto-field-vect)
   (extended-fields :type (list-of protobuf-field) ;the extended fields defined in this message
                    :accessor proto-extended-fields
                    :initform ())
   (extensions :type (list-of protobuf-extension) ;any extension ranges
               :accessor proto-extensions
               :initarg :extensions
               :initform ())
   ;; :message is an ordinary message
   ;; :group is a (deprecated) group (kind of an "implicit" message)
   ;; :extends is an 'extends' to an existing message
   (message-type :type (member :message :group :extends)
                 :accessor proto-message-type
                 :initarg :message-type
                 :initform :message))
  (:documentation
   "The model class that represents a Protobufs message."))

(defmethod make-load-form ((m protobuf-message) &optional environment)
  (with-slots (class message-type alias) m
    (multiple-value-bind (constructor initializer)
        (make-load-form-saving-slots m :environment environment)
      (values (if (eq message-type :extends)
                constructor
                `(let ((m ,constructor))
                   (record-protobuf-object ',message-type m :message)
                   m))
              initializer))))

(defun record-protobuf-object (symbol message type)
  "Record the protobuf-metaobject MESSAGE with named by SYMBOL and
in the hash-table indicated by TYPE."
  ;; No need to record an extension, it's already been recorded
  (ecase type
    (:enum (setf (gethash symbol *enums*) message))
    (:message (setf (gethash symbol *messages*) message))
    (:alias (setf (gethash symbol *type-aliases*) message))))

(defmethod print-object ((m protobuf-message) stream)
  (if *print-escape*
    (print-unreadable-object (m stream :type t :identity t)
      (format stream "~S~@[ (alias for ~S)~]~@[ (group~*)~]~@[ (extended~*)~]"
              (and (slot-boundp m 'class) (proto-class m))
              (and (slot-boundp m 'alias) (proto-alias-for m))
              (and (slot-boundp m 'message-type) (eq (proto-message-type m) :group))
              (and (slot-boundp m 'message-type) (eq (proto-message-type m) :extends))))
    (format stream "~S" (and (slot-boundp m 'class) (proto-class m)))))

(defmethod proto-package ((message protobuf-message))
  (and (proto-parent message)
       (proto-package (proto-parent message))))

(defmethod proto-lisp-package ((message protobuf-message))
  (and (proto-parent message)
       (proto-lisp-package (proto-parent message))))

(defmethod proto-real-lisp-package ((message protobuf-message))
  (and (proto-parent message)
       (proto-real-lisp-package (proto-parent message))))

(defmethod make-qualified-name ((message protobuf-message) name)
  ;; The qualified name is the message name "dot" the name
  (let ((qual-name (strcat (proto-name message) "." name)))
    (if (proto-parent message)
      ;; If there's a parent for this message (either a message or
      ;; the schema), prepend the name (or package) of the parent
      (make-qualified-name (proto-parent message) qual-name)
      ;; Guard against a message in the middle of nowhere
      qual-name)))

(defgeneric find-field (message name &optional relative-to)
  (:documentation
   "Given a Protobufs message and a slot name, field name or index,
    returns the Protobufs field having that name."))

(defmethod find-field ((message protobuf-message) (name symbol) &optional relative-to)
  (declare (ignore relative-to))
  (find name (proto-fields message) :key #'proto-internal-field-name))

(defmethod find-field ((message protobuf-message) (name string) &optional relative-to)
  (find-qualified-name name (proto-fields message)
                       :relative-to (or relative-to message)))

(defmethod find-field ((message protobuf-message) (index integer) &optional relative-to)
  (declare (ignore relative-to))
  (find index (proto-fields message) :key #'proto-index))


;; Extensions protocol
(defgeneric get-extension (object slot)
  (:documentation
   "Returns the value of the extended slot SLOT in OBJECT."))

(defgeneric set-extension (object slot value)
  (:documentation
   "Sets the value of the extended slot SLOT to VALUE in OBJECT."))

(defgeneric has-extension (object slot)
  (:documentation
   "Returns true iff there is an extended slot named SLOT in OBJECT.")
  ;; It's an error to call {get,set,clear}-extension on a non-extendable object.
  (:method ((object standard-object) slot)
    (declare (ignore slot))
    nil))

(defgeneric clear-extension (object slot)
  (:documentation
   "Clears the value of the extended slot SLOT from OBJECT."))


(defconstant $empty-default 'empty-default
  "The marker used in 'proto-default' used to indicate that there is no default value.")
(defconstant $empty-list    'empty-list)
(defconstant $empty-vector  'empty-vector)

;; A Protobufs field within a message
;;--- Support the 'deprecated' option (have serialization ignore such fields?)
(defclass protobuf-field (base-protobuf)
  ((type :type string                           ; The name of the Protobuf type for the field
         :accessor proto-type
         :initarg :type)
   (lisp-type :type (or null string)            ; Override the name of the Lisp type for the field
              :accessor proto-lisp-type
              :initarg :lisp-type
              :initform nil)
   (set-type  :accessor proto-set-type          ; The type obtained directly
              :initarg :set-type)               ; from the protobuf schema.
   (label :type (member :required :optional :repeated)
          :accessor proto-label
          :initarg :label)
   (index :type (unsigned-byte 29)              ; The index number for this field
          :accessor proto-index                 ; which must be strictly positive
          :initarg :index)
   (field-offset :type (or null (unsigned-byte 29))
                 :accessor proto-field-offset
                 :initarg :field-offset)
   ;; The name of the slot holding the field value.
   ;; todo: there's no deep reason we must have internal and external field names. It's a
   ;; historical artifact that can probably be removed once the QPX protobuf code has been updated.
   (internal-field-name :type (or null symbol)
                        :accessor proto-internal-field-name
                        :initarg :internal-field-name
                        :initform nil)
   (external-field-name
    :type (or null symbol)                ; The Lisp slot holding the value within an object
    :accessor proto-external-field-name   ; this also serves as the Lisp field name
    :initarg :external-field-name
    :initform nil)
   (reader :type (or null symbol)               ; A reader that is used to access the value
           :accessor proto-reader               ; if it's supplied, it's used instead of 'value'
           :initarg :reader
           :initform nil)
   (writer :type (or null symbol list)          ; A writer that is used to set the value when
           :accessor proto-writer               ; it's a list, it's something like '(setf title)'
           :initarg :writer
           :initform nil)
   (default :accessor proto-default             ; Default value (untyped), pulled out of the options
            :initarg :default
            :initform $empty-default)
   (packed :type boolean                        ; Packed, pulled out of the options
           :accessor proto-packed
           :initarg :packed
           :initform nil)
   (lazy :type boolean                          ; Lazy, pulled out of the options
         :accessor proto-lazy-p
         :initarg :lazy
         :initform nil)
   (bool-index :type (or null integer)      ; For non-repeated boolean fields only, the
               :accessor proto-bool-index   ; index into the bit-vector of boolean field values.
               :initarg :bool-index
               :initform nil)
   ;; Copied from 'proto-message-type' of the field
   (message-type :type (member :message :group :extends)
                 :accessor proto-message-type
                 :initarg :message-type
                 :initform :message))
  (:documentation
   "The model class that represents one field within a Protobufs message."))

(defmethod initialize-instance :after ((field protobuf-field) &rest initargs)
  (declare (ignore initargs))
  (when (slot-boundp field 'index)
    (assert (and (plusp (proto-index field))
                 (not (<= 19000 (proto-index field) 19999))) ()
            "Protobuf field indexes must be positive and not between 19000 and 19999 (inclusive)")))

(defmethod make-load-form ((f protobuf-field) &optional environment)
  (make-load-form-saving-slots f :environment environment))

(defmethod print-object ((f protobuf-field) stream)
  (if *print-escape*
      (print-unreadable-object (f stream :type t :identity t)
        (format stream "~S :: ~S = ~D~@[ (group~*)~]~@[ (extended~*)~]"
                (proto-internal-field-name f)
                (and (slot-boundp f 'class) (proto-class f))
                (proto-index f)
                (eq (proto-message-type f) :group)
                (eq (proto-message-type f) :extends)))
      (format stream "~S" (proto-internal-field-name f))))

(defmethod proto-slot ((field protobuf-field))
  (proto-internal-field-name field))

(defmethod (setf proto-slot) (slot (field protobuf-field))
  (setf (proto-value field) slot))

(defgeneric empty-default-p (field)
  (:documentation
   "Returns true iff the default for the field is empty, ie, was not supplied.")
  (:method ((field protobuf-field))
    (let ((default (proto-default field)))
      (or (eq default $empty-default)
          (eq default $empty-list)
          (eq default $empty-vector)
          ;; Special handling for imported CLOS classes
          (and (not (eq (proto-label field) :optional))
               (or (null default) (equalp default #())))))))

(defgeneric vector-field-p (field)
  (:documentation
   "Returns true if the storage for a 'repeated' field is a vector,
    returns false if the storage is a list.")
  (:method ((field protobuf-field))
    ;; NB: the FieldOption (lisp_container) attempts to generalize whether a repeated field is a
    ;; list or a vector, but for now the only indication that a protobuf-field wants to be a vector
    ;; is what its default is.
    (let ((default (proto-default field)))
      (or (eq default $empty-vector)
          (and (vectorp default) (not (stringp default)))))))


;; An extension range within a message
(defclass protobuf-extension (abstract-protobuf)
  ((from :type (integer 1 #.(1- (ash 1 29)))    ;the index number for this field
         :accessor proto-extension-from
         :initarg :from)
   (to :type (integer 1 #.(1- (ash 1 29)))      ;the index number for this field
       :accessor proto-extension-to
       :initarg :to))
  (:documentation
   "The model class that represents an extension range within a Protobufs message."))

(defvar *all-extensions* nil)
(defmethod make-load-form ((e protobuf-extension) &optional environment)
  (declare (ignore environment))
  (let ((from (and (slot-boundp e 'from) (proto-extension-from e)))
        (to (and (slot-boundp e 'to) (proto-extension-to e))))
    `(or (cdr (assoc '(,from . ,to) *all-extensions* :test #'equal))
         (let ((obj (make-instance 'protobuf-extension
                                   ,@(and from `(:from ,from))
                                   ,@(and to `(:to ,to)))))
           (push (cons '(,from . ,to) obj) *all-extensions*)
           obj))))

(defmethod print-object ((e protobuf-extension) stream)
  (print-unreadable-object (e stream :type t :identity t)
    (format stream "~D - ~D"
            (proto-extension-from e) (proto-extension-to e))))


;; A Protobufs service
(defclass protobuf-service (base-protobuf)
  ((methods :type (list-of protobuf-method)     ;the methods in the service
            :accessor proto-methods
            :initarg :methods
            :initform ()))
  (:documentation
   "The model class that represents a Protobufs service."))

(defmethod make-load-form ((s protobuf-service) &optional environment)
  (make-load-form-saving-slots s :environment environment))

(defmethod print-object ((s protobuf-service) stream)
  (if *print-escape*
    (print-unreadable-object (s stream :type t :identity t)
      (format stream "~S" (proto-name s)))
    (format stream "~S" (proto-name s))))

(defgeneric find-method (service name)
  (:documentation
   "Given a Protobufs service and a method name,
    returns the Protobufs method having that name."))

(defmethod find-method ((service protobuf-service) (name symbol))
  (find name (proto-methods service) :key #'proto-class))

(defmethod find-method ((service protobuf-service) (name string))
  (find-qualified-name name (proto-methods service)))

(defmethod find-method ((service protobuf-service) (index integer))
  (find index (proto-methods service) :key #'proto-index))


;; A Protobufs method within a service
(defclass protobuf-method (base-protobuf)
  ((client-fn :type symbol                      ;the Lisp name of the client stb
              :accessor proto-client-stub
              :initarg :client-stub)
   (server-fn :type symbol                      ;the Lisp name of the server stb
              :accessor proto-server-stub
              :initarg :server-stub)
   (itype :type symbol                          ;the Lisp type name of the input
          :accessor proto-input-type
          :initarg :input-type)
   (iname :type (or null string)                ;the Protobufs name of the input
          :accessor proto-input-name
          :initarg :input-name
          :initform nil)
   (istreaming :type boolean                    ;for stubby4-style streaming.
               :accessor proto-input-streaming-p
               :initarg :input-streaming
               :initform nil)
   (otype :type symbol                          ;the Lisp type name of the output
          :accessor proto-output-type
          :initarg :output-type)
   (oname :type (or null string)                ;the Protobufs name of the output
          :accessor proto-output-name
          :initarg :output-name
          :initform nil)
   (ostreaming :type boolean                    ;for stubby4-style streaming.
               :accessor proto-output-streaming-p
               :initarg :output-streaming
               :initform nil)
   (stype :type (or symbol null)                ;the Lisp type name of the "streams" type
          :accessor proto-streams-type
          :initarg :streams-type
          :initform nil)
   (sname :type (or null string)                ;the Protobufs name of the "streams" type
          :accessor proto-streams-name
          :initarg :streams-name
          :initform nil)
   (index :type (unsigned-byte 32)              ;an identifying index for this method
          :accessor proto-index                 ; (used by the RPC implementation)
          :initarg :index))
  (:documentation
   "The model class that represents one method with a Protobufs service."))

(defmethod make-load-form ((m protobuf-method) &optional environment)
  (make-load-form-saving-slots m :environment environment))

(defmethod print-object ((m protobuf-method) stream)
  (if *print-escape*
    (print-unreadable-object (m stream :type t :identity t)
      (format stream "~S (~S) => (~S)"
              (proto-class m)
              (and (slot-boundp m 'itype) (proto-input-type m))
              (and (slot-boundp m 'otype) (proto-output-type m))))
    (format stream "~S" (proto-class m))))


;;; Lisp-only extensions

;; A Protobufs message
(defclass protobuf-type-alias (base-protobuf)
  ((lisp-type :reader proto-lisp-type           ;a Lisp type specifier
              :initarg :lisp-type)
   (proto-type :reader proto-proto-type         ;a .proto type specifier
               :initarg :proto-type)
   (proto-type-str :reader proto-proto-type-str
               :initarg :proto-type-str)
   (serializer :reader proto-serializer         ;Lisp -> Protobufs conversion function
               :initarg :serializer)
   (deserializer :reader proto-deserializer     ;Protobufs -> Lisp conversion function
                 :initarg :deserializer))
  (:documentation
   "The model class that represents a Protobufs type alias."))

(defmethod make-load-form ((m protobuf-type-alias) &optional environment)
  (make-load-form-saving-slots m :environment environment))

(defmethod print-object ((m protobuf-type-alias) stream)
  (if *print-escape*
    (print-unreadable-object (m stream :type t :identity t)
      (format stream "~S (maps ~S to ~S)"
              (proto-class m)
              (proto-lisp-type m) (proto-proto-type m)))
    (format stream "~S" (proto-class m))))

(defgeneric set-method-do-not-deserialize-input (method)
  (:documentation
   "Sets a service METHOD to indicate that its input should not be deserialized prior to calling its
    server function.")
  (:method ((method protobuf-method))
    (setf (proto-impl:proto-input-type method) nil)))