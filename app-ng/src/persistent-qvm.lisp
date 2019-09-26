;;;; api/persistent-qvm.lisp
;;;;
;;;; Author: appleby

(in-package :qvm-app-ng)

(deftype persistent-qvm-token () 'string)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun make-empty-persistent-qvms-db ()
    (make-hash-table :test 'equal)))

(global-vars:define-global-var **persistent-qvms** (make-empty-persistent-qvms-db)
  "The database of persistent QVMs. The keys are integers and the values are lists of (QVM LOCK METADATA) triples.")

(global-vars:define-global-var **persistent-qvms-lock** (bt:make-lock "Persistent QVMs DB Lock"))

(defun reset-persistent-qvms-db ()
  "Reset the **PERSISTENT-QVMS** database."
  (bt:with-lock-held (**persistent-qvms-lock**)
    (setf **persistent-qvms** (make-empty-persistent-qvms-db))))

(defun persistent-qvms-count ()
  "Return the number of PERSISTENT-QVMS currently allocated."
  (bt:with-lock-held (**persistent-qvms-lock**)
    (hash-table-count **persistent-qvms**)))

(deftype persistent-qvm-state () '(member ready running waiting resuming dying))

(alexandria:define-constant +valid-pqvm-state-transitions+
    '((ready    running           dying)
      (running  ready    waiting  dying)
      (waiting  resuming          dying)
      (resuming running           dying)
      (dying                      dying))
  :test #'equal
  :documentation "An alist of valid state transitions for a PERSISTENT-QVM. The alist is keyed on the current state. The value for each key is list of states that can be transitioned to from the corresponding current state.")

(defun %checked-transition-to-state-locked (pqvm new-state)
  (unless (member new-state (cdr (assoc (persistent-qvm-state pqvm) +valid-pqvm-state-transitions+)))
    (error "Attempting invalid state transition ~A -> ~A for Persistent QVM ~A"
           (persistent-qvm-state pqvm)
           new-state
           (persistent-qvm-token pqvm)))
  (setf (persistent-qvm-state pqvm) new-state))

(defstruct (persistent-qvm (:constructor %make-persistent-qvm))
  (qvm      (error "Must provide QVM")                                 :read-only t)
  (cv       (error "Must provide CV")                                  :read-only t)
  (lock     (error "Must provide LOCK")                                :read-only t)
  (state    (error "Must provide STATE")    :type persistent-qvm-state)
  (token    (error "Must provide TOKEN")    :type persistent-qvm-token :read-only t)
  (metadata (error "Must provide METADATA") :type hash-table           :read-only t))

(defun make-persistent-qvm-metadata (allocation-method)
  "Make a hash-table suitable a new PERSISTENT-QVM's METADATA slot."
  (alexandria:plist-hash-table (list "allocation-method" (symbol-name allocation-method)
                                     "created" (iso-time))
                               :test 'equal))

(defun make-persistent-qvm (qvm allocation-method token)
  "Make a PERSISTENT-QVM.

This function only returns a new PERSISTENT-QVM object. External callers probably want ALLOCATE-PERSISTENT-QVM, instead.

QVM is any QVM type (PURE-STATE-QVM, NOISY-QVM, etc).

ALLOCATION-METHOD is one of +AVAILABLE-ALLOCATION-METHODS+. This only provided so that it can be recorded in the PERSISTENT-QVM's metadata.

TOKEN is a PERSISTENT-QVM-TOKEN."
  (let* ((lock (bt:make-lock "PQVM Lock"))
         (cv (bt:make-condition-variable :name "PQVM CV"))
         (pqvm (%make-persistent-qvm :qvm qvm
                                     :cv cv
                                     :lock lock
                                     :state 'ready
                                     :token token
                                     :metadata (make-persistent-qvm-metadata allocation-method))))
    (setf (slot-value qvm 'qvm::wait-function)
          (lambda (qvm)
            (declare (ignore qvm))
            ;; LOCK must be held here or we're in trouble.
            (%checked-transition-to-state-locked pqvm 'waiting)
            ;; TODO:(appleby) possible to unwind from CONDITION-WAIT? Maybe UNWIND-PROTECT here.
            (loop :while (eq 'waiting (persistent-qvm-state pqvm))
                  :do (bt:condition-wait cv lock)
                  :finally (unless (eq 'dying (persistent-qvm-state pqvm))
                             (%checked-transition-to-state-locked pqvm 'running)))))
    pqvm))

(defmacro with-locked-pqvm ((pqvm) token &body body)
  "Execute BODY with PQVM bound to the persistent QVM identified by TOKEN.

BODY is executed with the persistent QVM's lock held. No other guarantees are made about the state of the persistent QVM. It's up to the caller to check that the persistent QVM's state is consistent inside BODY. Specifically, the persistent QVM may already be marked for deletion or in the WAITING state, etc. For this reason, callers should prefer the higher-level interface WITH-PERSISTENT-QVM when they only need safe access to the persistent QVM's underlying QVM object."
  (check-type pqvm symbol)
  (alexandria:once-only (token)
    `(let ((,pqvm (%lookup-persistent-qvm-or-lose ,token)))
       (declare (ignorable ,pqvm))
       (bt:with-lock-held ((persistent-qvm-lock ,pqvm))
         ,@body))))

(defmacro with-persistent-qvm ((qvm) token &body body)
  "Execute BODY with QVM bound to the QVM object owned by the persistent QVM corresponding to TOKEN.

BODY is executed with the persistent QVM's lock held, and an error is signaled if the persistent QVM is dying."
  (check-type qvm symbol)
  (alexandria:with-gensyms (pqvm)
    (alexandria:once-only (token)
      `(with-locked-pqvm (,pqvm) ,token
         (with-slots ((,qvm qvm)) ,pqvm
           (declare (ignorable ,qvm))
           (case (persistent-qvm-state ,pqvm)
             (dying (error "Persistent QVM ~A is marked for deletion." ,token))
             (t ,@body)))))))

(defun %insert-persistent-qvm-locked (token persistent-qvm)
  (setf (gethash token **persistent-qvms**) persistent-qvm))

(defun delete-persistent-qvm (token)
  "Delete the PERSISTENT-QVM indicated by TOKEN."
  (with-locked-pqvm (pqvm) token
    (%checked-transition-to-state-locked pqvm 'dying))
  (bt:with-lock-held (**persistent-qvms-lock**)
    (remhash token **persistent-qvms**)))

(defun %lookup-persistent-qvm-locked (token)
  (gethash token **persistent-qvms**))

(defun %lookup-persistent-qvm (token)
  (bt:with-lock-held (**persistent-qvms-lock**)
    (%lookup-persistent-qvm-locked token)))

(defun %lookup-persistent-qvm-or-lose (token)
  (or (%lookup-persistent-qvm token)
      (error "Failed to find persistent QVM ~D" token)))

(defun canonicalize-persistent-qvm-token (token)
  "Canonicalize the TOKEN string into the case expected by VALID-PERSISTENT-QVM-TOKEN-P."
  ;; Standardize on the more common (and more readable) lowercase UUID string, even though
  ;; UUID:PRINT-OBJECT and UUID:PRINT-BYTES print them in uppercase.
  (string-downcase token))

(defun uuid->persistent-qvm-token (uuid)
  "Convert UUID to a canonicalized PERSISTENT-QVM-TOKEN."
  (canonicalize-persistent-qvm-token (princ-to-string uuid)))

(defun make-persistent-qvm-token ()
  "Return a new persistent QVM token."
  (uuid->persistent-qvm-token
   (bt:with-lock-held (**persistent-qvms-lock**)
     ;; UUID:MAKE-V4-UUID is not thread safe. If you call it without locking, you get collisions. We
     ;; reuse **PERSISTENT-QVMS-LOCK** here to avoid needing to acquire two separate locks in order
     ;; to allocate a new persistent QVM. We could potentially avoid locking by always creating a
     ;; thread-local binding for UUID:*UUID-RANDOM-STATE*, but since we only ever generate a new
     ;; token at allocation time when we already hold the **PERSISTENT-QVMS-LOCK**, it's convenient
     ;; to reuse it. In fact, at allocation time we call %MAKE-PERSISTENT-QVM-TOKEN-LOCKED. This
     ;; locking version is provided for external code (like tests) that want to safely generate a
     ;; valid persistent token without foisting the burden of thread-safe access on the caller.
     (uuid:make-v4-uuid))))

(defun %make-persistent-qvm-token-locked ()
  (uuid->persistent-qvm-token (uuid:make-v4-uuid)))

(defun valid-persistent-qvm-token-p (token)
  "True if TOKEN is a valid string representation of a v4 UUID.

Note that this function requires that any hexadecimal digits in TOKEN are lowercased."
  ;; See RFC 4122 for UUID format.
  ;; https://tools.ietf.org/html/rfc4122#section-4.1
  ;;
  ;; We validate that token is a valid v4 UUID in printed string format. That is, as a string of
  ;; hexadecimal digits (with certain restrictions) separated by hyphens in the expected places.
  (and (typep token 'persistent-qvm-token)
       (= (length token) 36)
       (eql (aref token  8) #\-)
       (eql (aref token 13) #\-)
       (eql (aref token 14) #\4) ; version
       (eql (aref token 18) #\-)
       ;; https://tools.ietf.org/html/rfc4122#section-4.4
       ;; The two most-significant bits of the clock sequence field are #b10, meaning the
       ;; resulting hex digit of the most-significant byte is one of 8, 9, a, or b.
       (find (aref token 19) "89ab")
       (eql (aref token 23) #\-)
       (every (lambda (c)
                (find c "-0123456789abcdef"))
              token)))

(defun allocate-persistent-qvm (qvm allocation-method)
  "Allocate a new PERSISTENT-QVM.

QVM is a QVM object of any type (PURE-STATE-QVM, NOISY-QVM, etc.)

ALLOCATION-METHOD should be one of the +AVAILABLE-ALLOCATION-METHODS+, and is used when creating the PERSISTENT-QVM's metadata."
  (bt:with-lock-held (**persistent-qvms-lock**)
    (let ((token (%make-persistent-qvm-token-locked)))
      (cond ((not (null (%lookup-persistent-qvm-locked token)))
             (error "Token collision while attempting to allocate persistent QVM: ~S" token))
            (t (let ((persistent-qvm (make-persistent-qvm qvm allocation-method token)))
                 (%insert-persistent-qvm-locked token persistent-qvm)
                 (values token persistent-qvm)))))))

(defun persistent-qvm-info (token)
  "Return a HASH-TABLE of information about the PERSISTENT-QVM identified by TOKEN.

TOKEN is a PERSISTENT-QVM-TOKEN."
  (alexandria:plist-hash-table
   (with-locked-pqvm (pqvm) token
     (list "qvm-type" (symbol-name (type-of (persistent-qvm-qvm pqvm)))
           "num-qubits" (qvm:number-of-qubits (persistent-qvm-qvm pqvm))
           "state" (symbol-name (persistent-qvm-state pqvm))
           "metadata" (persistent-qvm-metadata pqvm)))
   :test 'equal))

(defun run-program-on-persistent-qvm (token parsed-program)
  "Run the given PARSED-PROGRAM on the PERSISTENT-QVM indicated by TOKEN.

Returns NIL or signals an error if the given PERSISTENT-QVM is not in the READY state."
  (with-locked-pqvm (pqvm) token
    (case (persistent-qvm-state pqvm)
      (ready
       (%checked-transition-to-state-locked pqvm 'running)
       (unwind-protect (run-program-on-qvm (persistent-qvm-qvm pqvm) parsed-program)
         (%checked-transition-to-state-locked pqvm 'ready)))
      (t
       (error "Cannot run program on Persistent QVM ~A in state ~A."
              token
              (persistent-qvm-state pqvm))))
    nil))

(defun write-persistent-qvm-memory (token memory-contents)
  "Write MEMORY-CONTENTS in the classical memory of the given PERSISTENT-QVM.

TOKEN is a PERSISTENT-QVM-TOKEN.

MEMORY-CONTENTS is a HASH-TABLE where each key is a string indicating the memory register name and the corresponding value is a LIST of (INDEX VALUE) pairs indicating that VALUE should be stored at index INDEX in the corresponding memory register.

Returns NIL."
  (with-persistent-qvm (qvm) token
    (maphash (lambda (k v)
               (loop :for (index value) :in v :do
                 (setf (qvm:memory-ref qvm k index) value)))
             memory-contents)))

(defun resume-persistent-qvm (token)
  "Resume the PERSISTENT-QVM indicated by TOKEN.

TOKEN is a PERSISTENT-QVM-TOKEN.

Returns NIL or signals an error if the given PERSISTENT-QVM is not in the WAITING state."
  (with-locked-pqvm (pqvm) token
    (%checked-transition-to-state-locked pqvm 'resuming)
    (bt:condition-notify (persistent-qvm-cv pqvm)))
  nil)
