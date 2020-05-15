;;; Copyright 2012-2020 Google LLC
;;;
;;; Use of this source code is governed by an MIT-style
;;; license that can be found in the LICENSE file or at
;;; https://opensource.org/licenses/MIT.

(in-package "PROTO-IMPL")


;;; Protocol buffers wire format

;;; Utilities

(eval-when (:compile-toplevel :load-toplevel :execute)

  ;; Warning:
  ;; If you need to debug the (de)serializer, (pushnew :debug-serialization *features*)
  ;; Otherwise, we remove type checking and type conversion
  ;; from the (de)serializers for speed.
  ;; For the cl-protobuf this is fine, we will make a guarantee that
  ;; we will serialize/deserialize the right type.
  ;;
  ;; Note: The debugging feature should be used cautiously, you
  ;; can run into bugs by running in debug mode and getting type-conversion
  ;; then turning off debug mode and getting type failures.
  ;; This is because debug mode turns on type checking and type conversion.
  (defparameter $optimize-serialization
    #+debug-serialization $optimize-default
    #-debug-serialization $optimize-fast-unsafe)

  (defconstant $wire-type-varint 0)
  (defconstant $wire-type-64bit  1)
  (defconstant $wire-type-string 2)
  (defconstant $wire-type-start-group 3)          ;supposedly deprecated, but no such luck
  (defconstant $wire-type-end-group   4)          ;supposedly deprecated
  (defconstant $wire-type-32bit  5)

  )       ;eval-when


(defun make-tag (type index)
  "Given a wire type or the name of a Protobufs type and a field index,
   return the tag that encodes both of them."
  (locally (declare #.$optimize-serialization)
    (if (typep type 'fixnum)
      (ilogior type (iash index 3))
      (let ((type (ecase type
                    ((:int32 :uint32) $wire-type-varint)
                    ((:int64 :uint64) $wire-type-varint)
                    ((:sint32 :sint64) $wire-type-varint)
                    ((:fixed32 :sfixed32) $wire-type-32bit)
                    ((:fixed64 :sfixed64) $wire-type-64bit)
                    ((:string :bytes) $wire-type-string)
                    ((:bool) $wire-type-varint)
                    ((:float) $wire-type-32bit)
                    ((:double) $wire-type-64bit)
                    ;; A few of our homegrown types
                    ((:symbol) $wire-type-string)
                    ((:date :time :datetime :timestamp) $wire-type-64bit))))
        (ilogior type (iash index 3))))))

(define-compiler-macro make-tag (&whole form type index)
  (setq type (fold-symbol type))
  (cond ((typep type 'fixnum)
         `(ilogior ,type (iash ,index 3)))
        ((keywordp type)
         (let ((type (ecase type
                       ((:int32 :uint32) $wire-type-varint)
                       ((:int64 :uint64) $wire-type-varint)
                       ((:sint32 :sint64) $wire-type-varint)
                       ((:fixed32 :sfixed32) $wire-type-32bit)
                       ((:fixed64 :sfixed64) $wire-type-64bit)
                       ((:string :bytes) $wire-type-string)
                       ((:bool) $wire-type-varint)
                       ((:float) $wire-type-32bit)
                       ((:double) $wire-type-64bit)
                       ;; A few of our homegrown types
                       ((:symbol) $wire-type-string)
                       ((:date :time :datetime :timestamp) $wire-type-64bit))))
           `(ilogior ,type (iash ,index 3))))
        (t form)))

;; BUG: FOLD-SYMBOL is just wrong. It's not "intrinsically" broken - it behaves exactly as it
;; is documented to, however *using* it is broken with respect to ordinary Lisp semantics.
;; Suppose the following have been defined:
;;  (defconstant a 'b)
;;  (defconstant b :bool)
;; Then (SERIALIZE-PRIM x a tag buffer) should generate a runtime error, because the symbol B,
;; which is what the function receives, is not a known primitive.
;; However FOLD-SYMBOL translates A into :BOOL.
;; Compiler-macros should never alter a form's semantics.
;;
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun fold-symbol (x)
    "Given an expression 'x', constant-fold it until it can be folded no more."
    (let ((last '#:last))
      (loop
        (cond ((eq x last) (return x))
              ((and (listp x)
                    (eq (first x) 'quote)
                    (constantp (second x)))
               (shiftf last x (second x)))
              ((and (symbolp x)
                    (boundp x))
               (shiftf last x (symbol-value x)))
              (t (return x)))))))

(defun packed-tag (index)
  "Takes a field INDEX, and returns a tag for a packed field with that same index."
  (declare (type (unsigned-byte 32) index))
  (make-tag $wire-type-string index))

(defun length-encoded-tag-p (tag)
  "Returns non-nil if TAG represents a length-encoded field.

   Otherwise nil."
  (declare (type (unsigned-byte 32) tag))
  (= $wire-type-string (ldb (byte 3 0) tag)))

(defmacro gen-zig-zag (bits)
  "Generate 32- or 64-bit versions of zig-zag encoder/decoder."
  (assert (and (plusp bits) (zerop (mod bits 8))))
  (let* ((zig-zag-encode (fintern "~A~A" 'zig-zag-encode bits))
         (zig-zag-decode (fintern "~A~A" 'zig-zag-decode bits))
         (zig-zag-shift (1+ (- bits))))
    `(progn
       (defun ,zig-zag-encode (val)
         (declare #.$optimize-serialization)
         (declare (type (signed-byte ,bits) val))
         (logxor (ash val 1) (ash val ,zig-zag-shift)))
       (define-compiler-macro ,zig-zag-encode (&whole form val)
         (if (atom val)
           `(locally (declare #.$optimize-serialization
                              (type (signed-byte ,',bits) ,val))
              (logxor (ash ,val 1) (ash ,val ,',zig-zag-shift)))
           form))
       (defun ,zig-zag-decode (val)
         (declare #.$optimize-serialization)
         (declare (type (unsigned-byte ,bits) val))
         (logxor (ash val -1) (- (logand val 1))))
       (define-compiler-macro ,zig-zag-decode (&whole form val)
         (if (atom val)
           `(locally (declare #.$optimize-serialization
                              (type (unsigned-byte ,',bits) ,val))
              (logxor (ash ,val -1) (- (logand ,val 1))))
           form)))))

(gen-zig-zag 32)
(gen-zig-zag 64)


;;; Serializers

;; Serialize 'val' of primitive type 'type' into the buffer
(declaim (ftype (function (t t (unsigned-byte 32) t) (values fixnum &optional))
                serialize-prim))
(defun serialize-prim (val type tag buffer)
  "Serializes a Protobufs primitive (scalar) value into the buffer at the given index.
   The value is given by 'val', the primitive type by 'type'.
   Modifies the buffer in place, and returns the new index into the buffer.
   Watch out, this function turns off most type checking and all array bounds checking."
  (declare (type (unsigned-byte 32) tag))
  (locally (declare #.$optimize-serialization)
    (i+
     (encode-uint32 tag buffer)
     (ecase type
       ((:int32 :uint32) (encode-uint32 (ldb (byte 32 0) val) buffer))
       (:uint64          (encode-uint64 val buffer))
       (:int64           (encode-int64 val buffer))
       (:sint32          (encode-uint32 (zig-zag-encode32 val) buffer))
       (:sint64          (encode-uint64 (zig-zag-encode64 val) buffer))
       (:fixed32         (encode-fixed32 val buffer))
       (:sfixed32        (encode-sfixed32 val buffer))
       (:fixed64         (encode-fixed64 val buffer))
       (:sfixed64        (encode-sfixed64 val buffer))
       (:string          (encode-string val buffer))
       (:bytes           (encode-octets val buffer))
       (:bool            (encode-uint32 (if val 1 0) buffer))
       (:float           (encode-single val buffer))
       (:double          (encode-double val buffer))
       ;; A few of our homegrown types
       (:symbol
        ;; XXX: This implementation is bad. Should write one uint32 for the sum of
        ;; lengths of package-name and symbol-name plus 1, then the tokens.
        (let ((val (if (keywordp val)
                       (string val)
                       ;; Non-keyword symbols are consy, avoid them if possible
                       (format nil "~A:~A" (package-name (symbol-package val)) (symbol-name val)))))
          (encode-string val buffer)))
       ((:date :time :datetime :timestamp)
        (encode-int64 val buffer))))))

(defun get-prim-encoder-form (type val buffer)
  (case type
    (:uint32   `(encode-uint32 ,val ,buffer))
    (:uint64   `(encode-uint64 ,val ,buffer))
    (:int32    `(encode-uint32 (ldb (byte 32 0) ,val) ,buffer))
    (:int64    `(encode-int64 ,val ,buffer))
    (:sint32   `(encode-uint32 (zig-zag-encode32 ,val) ,buffer))
    (:sint64   `(encode-uint64 (zig-zag-encode64 ,val) ,buffer))
    (:fixed32  `(encode-fixed32 ,val ,buffer))
    (:sfixed32 `(encode-sfixed32 ,val ,buffer))
    (:fixed64  `(encode-fixed64 ,val ,buffer))
    (:sfixed64 `(encode-sfixed64 ,val ,buffer))
    (:string   `(encode-string ,val ,buffer))
    (:bytes    `(encode-octets ,val ,buffer))
    (:bool     `(encode-uint32 (if ,val 1 0) ,buffer))
    (:float    `(encode-single ,val ,buffer))
    (:double   `(encode-double ,val ,buffer))))

(defun get-prim-encoder-lambda (type)
  (ecase type
    (:uint32   (lambda (val b) (encode-uint32 val b)))
    (:uint64   (lambda (val b) (encode-uint64 val b)))
    (:int32    (lambda (val b) (encode-uint32 (ldb (byte 32 0) val) b)))
    (:int64    (lambda (val b) (encode-int64 val b)))
    ;; FIXME: should bury the zigzag algorithm into a specialized encoder.
    ;; Now we're consing bignums to pass to encode-uint64.
    (:sint32   (lambda (val b) (encode-uint32 (zig-zag-encode32 val) b)))
    (:sint64   (lambda (val b) (encode-uint64 (zig-zag-encode64 val) b)))
    (:fixed32  (lambda (val b) (encode-fixed32 val b)))
    (:sfixed32 (lambda (val b) (encode-sfixed32 val b)))
    (:fixed64  (lambda (val b) (encode-fixed64 val b)))
    (:sfixed64 (lambda (val b) (encode-sfixed64 val b)))
    (:bool     (lambda (val b) (encode-uint32 (if val 1 0) b)))
    (:float    (lambda (val b) (encode-single val b)))
    (:double   (lambda (val b) (encode-double val b)))))

(define-compiler-macro serialize-prim (&whole form val type tag buffer)
  (setq type (fold-symbol type)
        tag  (fold-symbol tag))
  (let ((encoder (get-prim-encoder-form type val buffer)))
    (if encoder
        `(locally (declare #.$optimize-serialization)
           (+ (encode-uint32 ,tag ,buffer) ,encoder))
        form)))

(declaim (ftype (function (t t &optional t) (values fixnum &optional))
                packed-size))
(defun serialize-packed (values type index buffer &optional vectorp)
  "Serializes a set of packed values into the buffer at the given index.
   The values are given by 'values', the primitive type by 'type'.
   Modifies the buffer in place, and returns the new index into the buffer.
   Watch out, this function turns off most type checking and all array bounds checking."
  (declare (type (unsigned-byte 32) index))
  ;; XXX: I have not tested this using the new BUFFER struct
  (locally (declare #.$optimize-serialization)
    #+sbcl (declare (notinline packed-size))
    (when (zerop (length values))
      (return-from serialize-packed 0))
    ;; It's not helpful to "inline" N different calls to MAP if the sequence
    ;; type is unknown - MAP can't be inlined in that case, so has to
    ;; act as a higher-order function. We can do slightly better by
    ;; actually specializing for two subtypes of sequence though.
    ;; Of course, we *could* dispatch on both the sequence type and the
    ;; primitive wire type, to create 22 (= 11 x 2) cases,
    ;; but I'm too lazy to hand-roll that, or even think of a macroish way.
    (let* ((encoder (get-prim-encoder-lambda type))
           (tag-len (encode-uint32 (packed-tag index) buffer))
           (payload-len (packed-size values type))
           (prefix-len (encode-uint32 payload-len buffer))
           (sum 0)) ; for double-check
      (declare (fixnum sum))
      (cond (vectorp
             (assert (vectorp values))
             (loop for x across values
                   while x
                   do (iincf sum (funcall encoder x buffer))))
            (t
             (assert (listp values))
             (dolist (x values)
               (iincf sum (funcall encoder x buffer)))))
      (assert (= sum payload-len))
      (i+ tag-len prefix-len payload-len))))

;; The optimized serializers supply 'vectorp' so we can generate better code
;; In SBCL this would be better as a transform sensitive to the type of VALUES.
;; I mean, really, an argument that decides if another argument is a vector? WTF?!
;;  ... you must be new here :)
(define-compiler-macro serialize-packed (&whole form values type index buffer
                                         &optional (vectorp nil vectorp-supplied-p))
  (setq type (fold-symbol type)
        index (fold-symbol index))
  (if vectorp-supplied-p
      (let ((encode (or (get-prim-encoder-form type 'val buffer)
                        (error "No primitive encoder for ~S" type))))
        ;; FIXME: probably should have ONCE-ONLY for BUFFER
        ;; [Same goes for a lot of the compiler macros]
        `(locally (declare #.$optimize-serialization)
           (if (zerop (length ,values)) 0
               ;; else
               (let* ((tag-len (encode-uint32 (packed-tag ,index) ,buffer))
                      (payload-len (packed-size ,values ,type ,vectorp))
                      (prefix-len (encode-uint32 payload-len ,buffer))
                      (sum 0)) ; for double-check
                 (declare (fixnum sum))
                 (,(if vectorp 'dovector 'dolist) (val ,values) (iincf sum ,encode))
                 (assert (= sum payload-len))
                 (i+ tag-len prefix-len payload-len)))))
      form))

(defun serialize-enum (val enum-values tag buffer)
  "Serializes a Protobufs enum value into the buffer at the given index.
   The value is given by 'val', the enum values are in 'enum-values'.
   Modifies the buffer in place, and returns the new index into the buffer.
   Watch out, this function turns off most type checking and all array bounds checking."
  (declare (type list enum-values)
           (type (unsigned-byte 32) tag))
  (locally (declare #.$optimize-serialization)
    (let ((val (let ((e (find val enum-values :key #'protobuf-enum-value-value)))
                 ;; This was not type-safe. What if E isn't found?
                 ;; It was emitting the low 32 bits of the NIL's machine representation.
                 ;; Seems perhaps better to emit something more concrete, namely 0.
                 (if e (protobuf-enum-value-index e) 0))))
      (declare (type (unsigned-byte 32) val))
      (i+ (encode-uint32 tag buffer) (encode-uint32 val buffer)))))

(defun serialize-packed-enum (values enum-values index buffer)
  "Serializes Protobufs enum values into the buffer at the given index.
   The values are given by 'values', the enum values are in 'enum-values'.
   Modifies the buffer in place, and returns the new index into the buffer.
   Watch out, this function turns off most type checking and all array bounds checking."
  (declare (type list enum-values)
           (type (unsigned-byte 32) index))
  (when (zerop (length values))
    (return-from serialize-packed-enum 0))
  (locally (declare #.$optimize-serialization)
    (let* ((tag-len (encode-uint32 (packed-tag index) buffer))
           (payload-len (packed-enum-size values enum-values))
           (prefix-len (encode-uint32 payload-len buffer))
           (sum 0)) ; for double-check
      (declare (type fixnum sum))
      (map nil
           (lambda (val)
             (let ((val (let ((e (find val enum-values :key #'protobuf-enum-value-value)))
                          (unless e (error "No such val ~S in amongst ~S" val enum-values))
                          (protobuf-enum-value-index e))))
               (declare (type (unsigned-byte 32) val))
               (iincf sum (encode-uint32 (ldb (byte 32 0) val) buffer))))
           values)
      (assert (= sum payload-len))
      (i+ tag-len prefix-len payload-len))))

;;; Deserializers

;;; Wire-level decoders
;;; These are called at the lowest level, so arg types are assumed to be correct

(declaim (ftype (function ((simple-array (unsigned-byte 8) (*)) array-index
                           (unsigned-byte 14) (member 32 64))
                          (values integer array-index))
                %decode-rest-of-uint))
(defun %decode-rest-of-uint (buffer index start-value max-bits)
   "Decodes the rest of the 64-bit varint integer in the BUFFER at the given INDEX.

    Assumes that the first two bytes of the integer have already been read from the buffer,
    resulting in START-VALUE.

    Returns both the decoded value and the new index into the buffer, and checks that the value fits
    in MAX-BITS.

    Watch out, this function turns off all type checking and array bounds checking."
  (declare (optimize (speed 3) (safety 0) (debug 0)))
  (flet ((get-byte ()
             (prog1 (aref buffer (the array-index index))
               (iincf index)))
         (return-as-correct-size (value)
           ;; Negative numbers are always encoded as ten bytes. We need to return just the MAX-BITS
           ;; low bits.
           (return-from %decode-rest-of-uint (values (ldb (byte max-bits 0) value) index))))
    (let ((fixnum-bits (* (floor (integer-length most-negative-fixnum) 7) 7))
          (bits-read 14)
          (low-word start-value))
      (declare (type fixnum low-word fixnum-bits))

      ;; Read as much as we can fit in a fixnum, and return as soon as we're done
      (loop for place from bits-read by 7 below fixnum-bits
            for byte fixnum = (get-byte)
            for bits = (ildb (byte 7 0) byte)
            do (setq low-word (ilogior (the fixnum low-word) (the fixnum (iash bits place))))
               (when (i< byte 128)
                 (return-as-correct-size low-word)))

      ;; Value doesn't fit into a fixnum. Read any additional values into another fixnum, and then
      ;; shift left and add to the low fixnum.
      (let ((high-word 0))
        (declare (type fixnum high-word))
        (loop for place from 0 by 7 below fixnum-bits
              for byte fixnum = (get-byte)
              for bits = (ildb (byte 7 0) byte)
              do (setq high-word (ilogior (the fixnum high-word) (the fixnum (iash bits place))))
                 (when (i< byte 128)
                   (return-as-correct-size (+ (ash high-word fixnum-bits) low-word)))))

      ;; We shouldn't get here unless we're reading a value that doesn't fit in two fixnums.
      (assert nil nil "The value doesn't fit into ~A bits" (* 2 fixnum-bits)))))

(declaim (ftype (function ((simple-array (unsigned-byte 8) (*)) array-index)
                          (values (unsigned-byte 64) array-index))
                decode-varint)
         (inline decode-varint))
(defun decode-varint (a index)
  (let ((word 0))
    (declare (type (simple-array (unsigned-byte 8) (*)) a)
             (type sb-ext:word word)
             (type sb-int:index index)
             (optimize (safety 0)))
    (let ((shift 0))
      (dotimes (i 10)
        (let ((byte (aref a index)))
          (incf index)
          (setf word
                (logior (logand (ash (logand byte 127) (the (mod 64) shift))
                                sb-ext:most-positive-word)
                        word))
          (unless (logbitp 7 byte) (return)))
        (incf shift 7)))
    (values word index)))

;; Decode the value from the buffer at the given index,
;; then return the value and new index into the buffer
;; These produce a storm of efficiency notes in SBCL.
(defmacro generate-integer-decoders (bits)
  "Generate 32- or 64-bit versions of integer decoders, specified by BITS."
  (assert (and (plusp bits) (zerop (mod bits 8))))
  (let* ((decode-uint (fintern "~A~A" 'decode-uint bits))
         (decode-int  (fintern "~A~A" 'decode-int bits))
         (decode-fixed  (fintern "~A~A" 'decode-fixed bits))
         (decode-sfixed (fintern "~A~A" 'decode-sfixed bits))
         (bytes (/ bits 8))
         ;; Given bits, can we use fixnums safely?
         (fixnump (<= bits (integer-length most-negative-fixnum)))
         (ldb (if fixnump 'ildb 'ldb))
         (ash (if fixnump 'iash 'ash))
         (decf (if fixnump 'idecf 'decf))
         (logior (if fixnump 'ilogior 'logior)))
    `(progn
       (declaim (ftype (function ((simple-array (unsigned-byte 8) (*)) array-index)
                                 (values (unsigned-byte ,bits) array-index))
                       ,decode-uint)
                (inline ,decode-uint))
       (defun ,decode-uint (buffer index)
         ,(format
           nil
           "Decodes the next ~A-bit varint integer in the buffer at the given index.~
           ~&    Returns both the decoded value and the new index into the buffer.~
           ~&    Watch out, this function turns off all type checking and array bounds checking."
           bits)
         (declare #.$optimize-serialization)
         (multiple-value-bind (val new-index)
             (decode-varint buffer index)
           ,@(when fixnump
               `((setf val (ildb (byte ,bits 0) val))))
           (values val new-index)))
       (declaim (ftype (function ((simple-array (unsigned-byte 8) (*)) array-index)
                                 (values (signed-byte ,bits) array-index))
                       ,decode-int)
                (inline ,decode-int))
       (defun ,decode-int (buffer index)
         ,(format
           nil
           "Decodes the next ~A-bit varint integer in the buffer at the given index.~
           ~&    Returns both the decoded value and the new index into the buffer.~
           ~&    Watch out, this function turns off all type checking and array bounds checking."
           bits)
         (declare #.$optimize-serialization)
         (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
                  (array-index index))
         (multiple-value-bind (val new-index)
             (decode-varint buffer index)
           (declare (type array-index new-index))
           (if (i= (ldb (byte 1 ,(1- bits)) val) 1)
               (values (the (signed-byte ,bits) (logior val ,(ash -1 bits))) new-index)
               (values val new-index))))
       (defun ,decode-fixed (buffer index)
         ,(format
           nil
           "Decodes the next ~A-bit unsigned fixed integer in the buffer at the given index.~
           ~&    Returns both the decoded value and the new index into the buffer.~
           ~&    Watch out, this function turns off all type checking and array bounds checking."
           bits)
         (declare #.$optimize-serialization)
         (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
                  (array-index index))
         ;; Eight bits at a time, least significant bits first
         (let ((val 0))
           ,@(when fixnump `((declare (type fixnum val))))
           (loop repeat ,bytes
                 for places fixnum upfrom 0 by 8
                 for byte fixnum = (prog1 (aref buffer index) (iincf index))
                 do (setq val (,logior val (,ash byte places))))
           (values val index)))
       (defun ,decode-sfixed (buffer index)
         ,(format
           nil
           "Decodes the next ~A-bit signed fixed integer in the buffer at the given index.~
           ~&    Returns both the decoded value and the new index into the buffer.~
           ~&    Watch out, this function turns off all type checking and array bounds checking."
           bits)
         (declare #.$optimize-serialization)
         (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
                  (array-index index))
         ;; Eight bits at a time, least significant bits first
         (let ((val 0))
           ,@(when fixnump `((declare (type fixnum val))))
           (loop repeat ,bytes
                 for places fixnum upfrom 0 by 8
                 for byte fixnum = (prog1 (aref buffer index) (iincf index))
                 do (setq val (,logior val (,ash byte places))))
           (when (i= (,ldb (byte 1 ,(1- bits)) val) 1)  ; sign bit set, so negative value
             (,decf val ,(ash 1 bits)))
           (values val index))))))

(generate-integer-decoders 32)
(generate-integer-decoders 64)

;; Deserialize the next object of type 'type'
;; FIXME: most of these are bad. QPX does not do much decoding,
;; so I'll not touch them for the time being.
(defun deserialize-prim (type buffer index)
  "Deserializes the next object of primitive type 'type'.
   Deserializes from the byte vector 'buffer' starting at 'index'.
   Returns the value and and the new index into the buffer.
   Watch out, this function turns off most type checking and all array bounds checking."
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
           (array-index index))
  (locally (declare #.$optimize-serialization)
    (ecase type
      (:int32    (decode-int32 buffer index))
      (:int64    (decode-int64 buffer index))
      (:uint32   (decode-uint32 buffer index))
      (:uint64   (decode-uint64 buffer index))
      (:sint32   (multiple-value-bind (val idx)
                     (decode-uint32 buffer index)
                   (values (zig-zag-decode32 val) idx)))
      (:sint64   (multiple-value-bind (val idx)
                     (decode-uint64 buffer index)
                   (values (zig-zag-decode64 val) idx)))
      (:fixed32  (decode-fixed32 buffer index))
      (:sfixed32 (decode-sfixed32 buffer index))
      (:fixed64  (decode-fixed64 buffer index))
      (:sfixed64 (decode-sfixed64 buffer index))
      (:string   (decode-string buffer index))
      (:bytes    (decode-octets buffer index))
      (:bool     (multiple-value-bind (val idx)
                     (decode-uint32 buffer index)
                   (values (if (i= val 0) nil t) idx)))
      (:float    (decode-single buffer index))
      (:double   (decode-double buffer index))
      ;; A few of our homegrown types
      ((:symbol)
       ;; Note that this is consy, avoid it if possible
       ;; XXX: This needn't cons. Just make strings displaced
       ;; to the data buffer.
       (multiple-value-bind (val idx)
           (decode-string buffer index)
         (values (make-lisp-symbol val) idx)))
      ((:date :time :datetime :timestamp)
       (decode-uint64 buffer index)))))

(define-compiler-macro deserialize-prim (&whole form type buffer index)
  (setq type (fold-symbol type))
  (let ((decoder
          (case type
            (:int32    `(decode-int32 ,buffer ,index))
            (:int64    `(decode-int64 ,buffer ,index))
            (:uint32   `(decode-uint32 ,buffer ,index))
            (:uint64   `(decode-uint64 ,buffer ,index))
            (:sint32   `(multiple-value-bind (val idx)
                            (decode-uint32 ,buffer ,index)
                          (values (zig-zag-decode32 val) idx)))
            (:sint64   `(multiple-value-bind (val idx)
                            (decode-uint64 ,buffer ,index)
                          (values (zig-zag-decode64 val) idx)))
            (:fixed32  `(decode-fixed32 ,buffer ,index))
            (:sfixed32 `(decode-sfixed32 ,buffer ,index))
            (:fixed64  `(decode-fixed64 ,buffer ,index))
            (:sfixed64 `(decode-sfixed64 ,buffer ,index))
            (:string   `(decode-string ,buffer ,index))
            (:bytes    `(decode-octets ,buffer ,index))
            (:bool     `(multiple-value-bind (val idx)
                            (decode-uint32 ,buffer ,index)
                          (values (if (i= val 0) nil t) idx)))
            (:float    `(decode-single ,buffer ,index))
            (:double   `(decode-double ,buffer ,index)))))
    (if decoder
        ;; The type declaration of BUFFER is essentially useless since these are
        ;; all out-of-line calls to unsafe functions, and we're not imparting any
        ;; more safety because this also elides type-checks.
        `(locally (declare #.$optimize-serialization
                           (type (simple-array (unsigned-byte 8) (*)) ,buffer)
                           (type fixnum ,index))
           ,decoder)
        form)))

(defun deserialize-packed (type buffer index)
  "Deserializes the next packed values of type 'type'.
   Deserializes from the byte vector 'buffer' starting at 'index'.
   Returns the value and and the new index into the buffer.
   Watch out, this function turns off most type checking and all array bounds checking."
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
           (array-index index))
  (locally (declare #.$optimize-serialization)
    (multiple-value-bind (len idx)
        (decode-uint32 buffer index)
      (declare (type (unsigned-byte 32) len)
               (type fixnum idx))
      (let ((end (i+ idx len)))
        (declare (type (unsigned-byte 32) end))
        (with-collectors ((values collect-value))
          (loop
            (when (>= idx end)
              (return-from deserialize-packed (values values idx)))
            (multiple-value-bind (val nidx)
                (ecase type
                  ((:int32)
                   (decode-int32 buffer idx))
                  ((:int64)
                   (decode-int64 buffer idx))
                  ((:uint32)
                   (decode-uint32 buffer idx))
                  ((:uint64)
                   (decode-uint64 buffer idx))
                  ((:sint32)
                   (multiple-value-bind (val nidx)
                       (decode-uint32 buffer idx)
                     (values (zig-zag-decode32 val) nidx)))
                  ((:sint64)
                   (multiple-value-bind (val nidx)
                       (decode-uint64 buffer idx)
                     (values (zig-zag-decode64 val) nidx)))
                  ((:fixed32)
                   (decode-fixed32 buffer idx))
                  ((:sfixed32)
                   (decode-sfixed32 buffer idx))
                  ((:fixed64)
                   (decode-fixed64 buffer idx))
                  ((:sfixed64)
                   (decode-sfixed64 buffer idx))
                  ((:bool)
                   (multiple-value-bind (val nidx)
                       (decode-uint32 buffer idx)
                     (values (if (i= val 0) nil t) nidx)))
                  ((:float)
                   (decode-single buffer idx))
                  ((:double)
                   (decode-double buffer idx)))
              (collect-value val)
              (setq idx nidx))))))))

(define-compiler-macro deserialize-packed (&whole form type buffer index)
  (setq type (fold-symbol type))
  (if (member type '(:int32 :uint32 :int64 :uint64 :sint32 :sint64
                     :fixed32 :sfixed32 :fixed64 :sfixed64
                     :bool :float :double))
    `(locally (declare #.$optimize-serialization
                       (type (simple-array (unsigned-byte 8) (*)) ,buffer)
                       (type fixnum ,index))
       (block deserialize-packed
         (multiple-value-bind (len idx)
             (decode-uint32 ,buffer ,index)
           (declare (type (unsigned-byte 32) len)
                    (type fixnum idx))
           (let ((end (i+ idx len)))
             (declare (type (unsigned-byte 32) end))
             (with-collectors ((values collect-value))
               (loop
                 (when (>= idx end)
                   (return-from deserialize-packed (values values idx)))
                 (multiple-value-bind (val nidx)
                     ,(ecase type
                        ((:int32)
                         `(decode-int32 ,buffer idx))
                        ((:int64)
                         `(decode-int64 ,buffer idx))
                        ((:uint32)
                         `(decode-uint32 ,buffer idx))
                        ((:uint64)
                         `(decode-uint64 ,buffer idx))
                        ((:sint32)
                         `(multiple-value-bind (val nidx)
                              (decode-uint32 ,buffer idx)
                            (values (zig-zag-decode32 val) nidx)))
                        ((:sint64)
                         `(multiple-value-bind (val nidx)
                              (decode-uint64 ,buffer idx)
                            (values (zig-zag-decode64 val) nidx)))
                        ((:fixed32)
                         `(decode-fixed32 ,buffer idx))
                        ((:sfixed32)
                         `(decode-sfixed32 ,buffer idx))
                        ((:fixed64)
                         `(decode-fixed64 ,buffer idx))
                        ((:sfixed64)
                         `(decode-sfixed64 ,buffer idx))
                        ((:bool)
                         `(multiple-value-bind (val nidx)
                              (decode-uint32 ,buffer idx)
                            (values (if (i= val 0) nil t) nidx)))
                        ((:float)
                         `(decode-single ,buffer idx))
                        ((:double)
                         `(decode-double ,buffer idx)))
                   (collect-value val)
                   (setq idx nidx))))))))
    form))

(defun deserialize-enum (enum-values buffer index)
  "Deserializes the next enum value take from 'enum-values'.
   Deserializes from the byte vector 'buffer' starting at 'index'.
   Returns the value and and the new index into the buffer.
   Watch out, this function turns off most type checking and all array bounds checking."
  (declare (type list enum-values)
           (type (simple-array (unsigned-byte 8) (*)) buffer)
           (array-index index))
  (locally (declare #.$optimize-serialization)
    (multiple-value-bind (val idx)
        (decode-int32 buffer index)
      (let ((val (let ((e (find val enum-values :key #'protobuf-enum-value-index)))
                   (and e (protobuf-enum-value-value e)))))
        (values val idx)))))

(defun deserialize-packed-enum (enum-values buffer index)
  "Deserializes the next packed enum values given in 'enum-values'.
   Deserializes from the byte vector 'buffer' starting at 'index'.
   Returns the value and and the new index into the buffer.
   Watch out, this function turns off most type checking and all array bounds checking."
  (declare (type list enum-values)
           (type (simple-array (unsigned-byte 8) (*)) buffer)
           (array-index index))
  (locally (declare #.$optimize-serialization)
    (multiple-value-bind (len idx)
        (decode-uint32 buffer index)
      (declare (type (unsigned-byte 32) len)
               (type fixnum idx))
      (let ((end (i+ idx len)))
        (declare (type (unsigned-byte 32) end))
        (with-collectors ((values collect-value))
          (loop
            (when (>= idx end)
              (return-from deserialize-packed-enum (values values idx)))
            (multiple-value-bind (val nidx)
                (decode-int32 buffer idx)
              (let ((val (let ((e (find val enum-values
                                        :key #'protobuf-enum-value-index)))
                           (and e (protobuf-enum-value-value e)))))
                (collect-value val)
                (setq idx nidx)))))))))

(defun packed-size (values type &optional vectorp)
  "Returns the size in bytes that the packed object will take when serialized.
   Watch out, this function turns off most type checking."
  (declare (ignore vectorp))
  (locally (declare #.$optimize-serialization)
    (let ((sum 0))
      (declare (type fixnum sum))
      (map nil
           (lambda (val)
             (iincf sum (ecase type
                          ((:int32 :uint32) (length32 val))
                          ((:int64 :uint64) (length64 val))
                          ((:sint32) (length32 (zig-zag-encode32 val)))
                          ((:sint64) (length64 (zig-zag-encode64 val)))
                          ((:fixed32 :sfixed32) 4)
                          ((:fixed64 :sfixed64) 8)
                          ((:bool)   1)
                          ((:float)  4)
                          ((:double) 8))))
           values)
      sum)))

;; The optimized serializers supply 'vectorp' so we can generate better code
(define-compiler-macro packed-size (&whole form values type
                                    &optional (vectorp nil vectorp-p))
  (setq type (fold-symbol type))
  (let ((size-form
          (case type
            (:int32  `(length32 val))
            (:int64  `(length64 val))
            (:uint32 `(length32 val))
            (:uint64 `(length64 val))
            (:sint32 `(length32 (zig-zag-encode32 val)))
            (:sint64 `(length64 (zig-zag-encode64 val)))
            ((:fixed32 :sfixed32) 4)
            ((:fixed64 :sfixed64) 8)
            (:bool   1)
            (:float  4)
            (:double 8))))
    (if (and vectorp-p size-form)
        `(locally (declare #.$optimize-serialization)
           (let ((sum 0))
             (declare (type fixnum sum))
             (,(if vectorp 'dovector 'dolist) (val ,values) (iincf sum ,size-form))
             sum))
        form)))

(defun packed-enum-size (values enum-values)
  "Returns the size in bytes that the enum values will take when serialized."
  (declare (type list enum-values))
  (let ((sum 0))
    (declare (type fixnum sum))
    (map nil
         (lambda (val)
           (let ((idx (let ((e (find val enum-values
                                     :key #'protobuf-enum-value-value)))
                        (and e (protobuf-enum-value-index e)))))
             (assert idx () "There is no enum value for ~S" val)
             (iincf sum (length32 (ldb (byte 32 0) idx)))))
         values)
    sum))

;;; Wire-level encoders
;;; These are called at the lowest level, so arg types are assumed to be correct

;; Todo: macroize the encoding loop for uint{32,64}
;; because it's repeated in a bunch of places.

(defun fast-octet-out-loop (buffer scratchpad count)
  (declare (type (simple-array octet-type 1) scratchpad))
  (dotimes (i count count)
    (fast-octet-out buffer (aref scratchpad i))))

(macrolet ((define-fixed-width-encoder (n-bytes name lisp-type accessor)
             `(progn
                (declaim (ftype (function (,lisp-type buffer)
                                          (values (eql ,n-bytes) &optional))
                                ,name))
                (defun ,name (val buffer)
                  (declare ,$optimize-serialization)
                  (declare (type ,lisp-type val))
                  ;; Don't worry about unaligned writes - they're still faster than
                  ;; looping. Todo: featurize for non-x86 and other than SBCL.
                  (if (buffer-ensure-space buffer ,n-bytes)
                      (let ((index (buffer-index buffer)))
                        (setf (,accessor (buffer-sap buffer) index) val
                              (buffer-index buffer) (+ index ,n-bytes))
                        ,n-bytes)
                      (let ((scratchpad (octet-buffer-scratchpad buffer)))
                        (setf (,accessor (sb-sys:vector-sap scratchpad) 0) val)
                        (fast-octet-out-loop buffer scratchpad ,n-bytes)))))))
  (define-fixed-width-encoder 4 encode-fixed32 (unsigned-byte 32) sb-sys:sap-ref-32)
  (define-fixed-width-encoder 8 encode-fixed64 (unsigned-byte 64) sb-sys:sap-ref-64)
  (define-fixed-width-encoder 4 encode-sfixed32 (signed-byte 32) sb-sys:signed-sap-ref-32)
  (define-fixed-width-encoder 8 encode-sfixed64 (signed-byte 64) sb-sys:signed-sap-ref-64)
  (define-fixed-width-encoder 4 encode-single single-float sb-sys:sap-ref-single)
  (define-fixed-width-encoder 8 encode-double double-float sb-sys:sap-ref-double))

(progn
(declaim (inline fast-utf8-encode))
(defun fast-utf8-encode (string)
  (sb-kernel:with-array-data ((string string) (start 0) (end nil)
                              :check-fill-pointer t)
    ;; This avoids calling GET-EXTERNAL-FORMAT at runtime.
    (funcall (load-time-value
              (sb-impl::ef-string-to-octets-fun
               (sb-impl::get-external-format-or-lose :utf-8)))
             string start end 0))))

;; The number of bytes to reserve to write a 'uint32' for the length of
;; a sub-message. In theory a uint32 should reserve 5 bytes,
;; but in submessage lengths can't, practically speaking, need that.
(defconstant +SUBMSG-LEN-SPACE-RESERVATION+ 4)

;; Convert a STRING to UTF-8 and write into BUFFER.
;; If the string is purely ASCII, no UTF-8 conversion occurs, and only one
;; pass over the string is required.
(declaim (ftype (function (string buffer) (values (unsigned-byte 32) &optional))
                encode-string))
(defun encode-string (string buffer)
  (declare #.$optimize-serialization)
  ;; The string doesn't technically have to be SIMPLE to allow the single-pass
  ;; optimization but I didn't feel like adding more hair.
  (when (simple-string-p string)
    (let ((strlen (length string)))
      ;; First ensure space, *then* mark where we are.
      (buffer-ensure-space buffer (+ strlen +SUBMSG-LEN-SPACE-RESERVATION+))
      (with-bookmark (buffer)
        ;; FAST-ENCODE merely skips a redundant call to ENSURE-SPACE
        (let ((prefix-len (fast-encode-uint32 strlen buffer)))
          (macrolet ((scan ()
                       `(dotimes (i strlen
                                  (return-from encode-string
                                    (+ prefix-len strlen)))
                         (let ((code (char-code (char string i))))
                           (if (< code 128)
                               (fast-octet-out buffer code)
                               (return))))))
            ;; "procedure cloning" elides the runtime per-character dispatch
            ;; based on whether the source string is UCS-4-encoded.
            ;; (The commonest case is UCS-4 but with no char-code over 127)
            ;; XXX: is there is a type that expresses UCS-4-encoded?
            ;; T works ok, since STRING is already known to be STRINGP.
            (typecase string
              (base-string (scan))
              (t (scan))))))))
  ;; Todo: If UTF-8 encoding is needed, it should be doable without an intermediate
  ;; temporary vector of octets, but the SBCL interface doesn't allow a caller-supplied
  ;; buffer, and the performance of Babel is pretty bad relative to native routines.
  (let* ((octets (the (simple-array octet-type (*)) (fast-utf8-encode string)))
         (len (length octets)))
    (buffer-ensure-space buffer (+ len +SUBMSG-LEN-SPACE-RESERVATION+))
    (incf len (fast-encode-uint32 len buffer)) ; LEN is now the resultant len
    (fast-octets-out buffer octets)
    len))

(defun encode-octets (octets buffer)
  (declare #.$optimize-serialization)
  (declare (type (array (unsigned-byte 8)) octets))
  (let ((len (length octets)))
    (buffer-ensure-space buffer (+ len +SUBMSG-LEN-SPACE-RESERVATION+))
    (incf len (encode-uint32 len buffer))
    (fast-octets-out buffer octets)
    len))


(defun decode-single (buffer index)
  "Decodes the next single float in the buffer at the given index.
   Returns both the decoded value and the new index into the buffer.
   Watch out, this function turns off all type checking and array bounds checking."
  (declare #.$optimize-serialization)
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
           (array-index index))
  #+sbcl
  (values (sb-sys:sap-ref-single (sb-sys:vector-sap buffer) index)
          (i+ index 4))
  ;; Eight bits at a time, least significant bits first
  #-sbcl
  (let ((bits 0))
    (loop repeat 4
          for places fixnum upfrom 0 by 8
          for byte fixnum = (prog1 (aref buffer index) (iincf index))
          do (setq bits (logior bits (ash byte places))))
    (when (i= (ldb (byte 1 31) bits) 1)             ;sign bit set, so negative value
      (decf bits #.(ash 1 32)))
    (values (make-single-float bits) index)))

(defun decode-double (buffer index)
  "Decodes the next double float in the buffer at the given index.
   Returns both the decoded value and the new index into the buffer.
   Watch out, this function turns off all type checking and array bounds checking."
  (declare #.$optimize-serialization)
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
           (array-index index))
  #+sbcl
  (values (sb-sys:sap-ref-double (sb-sys:vector-sap buffer) index)
          (i+ index 8))
  #-sbcl
  ;; Eight bits at a time, least significant bits first
  (let ((low  0)
        (high 0))
    (loop repeat 4
          for places fixnum upfrom 0 by 8
          for byte fixnum = (prog1 (aref buffer index) (iincf index))
          do (setq low (logior low (ash byte places))))
    (loop repeat 4
          for places fixnum upfrom 0 by 8
          for byte fixnum = (prog1 (aref buffer index) (iincf index))
          do (setq high (logior high (ash byte places))))
    ;; High bits are signed, but low bits are unsigned
    (when (i= (ldb (byte 1 31) high) 1)             ;sign bit set, so negative value
      (decf high #.(ash 1 32)))
    (values (make-double-float low high) index)))

(defun decode-string (buffer index)
  "Decodes the next UTF-8 encoded string in the buffer at the given index.
   Returns both the decoded string and the new index into the buffer.
   Watch out, this function turns off all type checking and array bounds checking."
  (declare #.$optimize-serialization)
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
           (array-index index))
  (multiple-value-bind (len idx)
      (decode-uint32 buffer index)
    (declare (type (unsigned-byte 32) len)
             (type fixnum idx))
    (values #+sbcl
            (let ((str (make-array len :element-type 'base-char)))
              (do ((src-idx (i+ idx len -1) (1- src-idx))
                   (dst-idx (1- len) (1- dst-idx)))
                  ((< dst-idx 0) str)
                (let ((byte (aref buffer src-idx)))
                  (if (< byte 128)
                      (setf (aref str dst-idx) (code-char byte))
                      (return
                        (sb-impl::utf8->string-aref buffer idx (i+ idx len)))))))
            #-sbcl
            (babel:octets-to-string buffer :start idx :end (i+ idx len) :encoding :utf-8)
            (i+ idx len))))

(defun decode-octets (buffer index)
  "Decodes the next octets in the buffer at the given index.
   Returns both the decoded value and the new index into the buffer.
   Watch out, this function turns off all type checking and array bounds checking."
  (declare #.$optimize-serialization)
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
           (array-index index))
  (multiple-value-bind (len idx)
      (decode-uint32 buffer index)
    (declare (type (unsigned-byte 32) len)
             (type fixnum idx))
    (values (subseq buffer idx (i+ idx len)) (i+ idx len))))


;;; Wire-level lengths
;;; These are called at the lowest level, so arg types are assumed to be correct

#+(and sbcl x86-64)
;; The SBCL code is faster by a factor of 6 than the generic code.
;; This is not very SBCL-specific other than a trick involving 'truly-the'.
(macrolet ((length-per-bits ()
             ;; A is indexed by bit number (0-based) of the highest 1 bit.
             (loop with a = (make-array 64 :element-type '(unsigned-byte 8))
                   for i from 1 to 64 ; I is the number of 1 bits
                   do (setf (aref a (1- i)) (ceiling i 7))
                   finally (return a))))
  (defun length32 (val)
    (declare (fixnum val) #.$optimize-serialization)
    (if (zerop val)
        1
        (aref (length-per-bits) (1- (integer-length (logand val (1- (ash 1 32))))))))
  ;; I didn't feel like pedantically defining separate variations on 'length64'
  ;; to accept signed or unsigned, so I just cheat and say that the number is signed-byte 64.
  ;; By doing that, any bignum is acceptable.
  (defun length64 (val)
    (declare (integer val) #.$optimize-serialization)
    (if (zerop val)
        1
        (aref (length-per-bits)
              (1- (integer-length (logand (sb-ext:truly-the (signed-byte 64) val)
                                          sb-vm::most-positive-word)))))))

#-sbcl
(defmacro gen-length (bits)
  "Generate 32- or 64-bit versions of integer length functions."
  (assert (and (plusp bits) (zerop (mod bits 8))))
  (let* (;; Given bits, can we use fixnums safely?
         (fixnump (<= bits (integer-length most-negative-fixnum)))
         (ash (if fixnump 'iash 'ash))
         (zerop-val (if fixnump '(i= val 0) '(zerop val))))
    `(defun ,(fintern "~A~A" 'length bits)
         (input &aux (val (logand input ,(1- (ash 1 bits)))))
       ,(format nil "Returns the length that 'val' will take when encoded as a ~A-bit integer." bits)
       (declare #.$optimize-serialization)
       (declare (type (or (unsigned-byte ,bits) (signed-byte ,bits)) input)
                (type (unsigned-byte ,bits) val))
       (let ((size 0))
         (declare (type fixnum size))
         (loop do (progn
                    (setq val (,ash val -7))
                    (iincf size))
               until ,zerop-val)
         size))))

#+(or (not sbcl) (not x86-64))
(progn
(gen-length 32)
(gen-length 64))

;;; Skipping elements
;;; This is called at the lowest level, so arg types are assumed to be correct

(defun skip-element (buffer index tag)
  "Skip an element in the buffer at the index of the given wire type.
   Returns the new index in the buffer.
   Watch out, this function turns off all type checking and all array bounds checking."
  (declare #.$optimize-serialization)
  (declare (type (simple-array (unsigned-byte 8) (*)) buffer)
           (array-index index)
           (type (unsigned-byte 32) tag))
  (case (ilogand tag #x7)
    ((#.$wire-type-varint)
     (loop for byte fixnum = (prog1 (aref buffer index) (iincf index))
           until (i< byte 128))
     index)
    ((#.$wire-type-string)
     (multiple-value-bind (len idx)
         (decode-uint32 buffer index)
       (declare (type (unsigned-byte 32) len)
                (type fixnum idx))
       (i+ idx len)))
    ((#.$wire-type-32bit)
     (i+ index 4))
    ((#.$wire-type-64bit)
     (i+ index 8))
    ((#.$wire-type-start-group)
     (loop (multiple-value-bind (new-tag idx)
               (decode-uint32 buffer index)
             (cond ((not (i= (ilogand new-tag #x7) $wire-type-end-group))
                    ;; If it's not the end of a group, skip the next element
                    (setq index (skip-element buffer idx new-tag)))
                   ;; If it's the end of the expected group, we're done
                   ((i= (i- tag $wire-type-start-group) (i- new-tag $wire-type-end-group))
                    (return idx))
                   (t
                    (assert (i= (i- tag $wire-type-start-group) (i- new-tag $wire-type-end-group)) ()
                            "Couldn't find a matching end group tag"))))))
    (t index)))