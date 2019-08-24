(in-package :qvm-app-ng)

(defvar *rpc-handlers* '())

(defun dispatch-rpc-handlers (request)
  (loop :for (rpc-method . handler) :in *rpc-handlers*
        :when (and (eq ':POST (tbnl:request-method request))
                   (string= "/" (tbnl:script-name request))
                   *request-json*
                   (string= rpc-method (gethash "type" *request-json*)))
          :do (return-from dispatch-rpc-handlers handler)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun remove-existing-rpc-handlers (rpc-method name)
    (remove-if (lambda (handler-spec)
                 (or (eq name (cdr handler-spec))
                     (string= rpc-method (car handler-spec))))
               *rpc-handlers*))

  (defun make-json-parameter (var)
    `(,var (and *request-json* (json-parameter ,(string-downcase (symbol-name var))))))

  (defun make-parsed-binding (parameter-spec)
    (destructuring-bind (var parse-function) parameter-spec
      `(,var (funcall (alexandria:ensure-function ,parse-function) ,var))))

  (defun valid-rpc-handler-lambda-list (lambda-list)
    (every (lambda (parameter-spec)
             (and (= 2 (length parameter-spec))
                  (symbolp (first parameter-spec))))
           lambda-list)))

(defmacro define-rpc-handler ((handler-name rpc-method) lambda-list &body body)
  (check-type handler-name symbol)
  (check-type rpc-method string)
  (assert (valid-rpc-handler-lambda-list lambda-list))
  `(progn
     (setf *rpc-handlers* (acons ,rpc-method ',handler-name
                                 (remove-existing-rpc-handlers ,rpc-method ',handler-name)))
     (defun ,handler-name (&key ,@(mapcar (alexandria:compose #'make-json-parameter #'first)
                                          lambda-list))
       (let (,@(mapcar #'make-parsed-binding lambda-list))
         ,@body))))

(defun collect-memory-registers (qvm addresses)
  (let ((results (make-hash-table :test 'equal)))
    (maphash (lambda (name indexes)
               (cond
                 ;; Give everything back.
                 ((eq indexes t)
                  (loop :with mv := (gethash name (qvm::classical-memories qvm))
                        :for idx :below (qvm::memory-view-length mv)
                        :collect (qvm:memory-ref qvm name idx) :into mem
                        :finally (push mem (gethash name results))))
                 ;; Give only some things back.
                 ((alexandria:proper-list-p indexes)
                  (loop :for idx :in indexes
                        :collect (qvm:memory-ref qvm name idx) :into mem
                        :finally (push mem (gethash name results))))
                 (t
                  (error "Invalid address parameter for memory named ~S." name))))
             addresses)
    results))

(define-rpc-handler (handle-create-qvm "create-qvm") ((simulation-method #'parse-simulation-method)
                                                      (num-qubits #'parse-num-qubits))
  (encode-json (alexandria:plist-hash-table
                (list "token" (allocate-persistent-qvm simulation-method num-qubits)))))

(define-rpc-handler (handle-delete-qvm "delete-qvm") ((qvm-token #'parse-qvm-token))
  (delete-persistent-qvm qvm-token)
  (encode-json (format nil "Deleted persistent QVM ~D" qvm-token)))

(define-rpc-handler (handle-qvm-info "qvm-info") ((qvm-token #'parse-qvm-token))
  (encode-json (persistent-qvm-info qvm-token)))

(define-rpc-handler (handle-run-program "run-program")
                    ((qvm-token #'parse-optional-qvm-token)
                     (simulation-method #'parse-optional-simulation-method)
                     (compiled-quil #'safely-parse-quil-string)
                     (addresses #'parse-addresses))
  (assert (or (null qvm-token) (null simulation-method)) ()
          "QVM-TOKEN and SIMULATION-METHOD cannot both be present in the JSON request parameters.")
  (encode-json
   (collect-memory-registers
    (if qvm-token
        (run-program-on-persistent-qvm qvm-token compiled-quil)
        (run-program-on-qvm (make-requested-qvm simulation-method (quil:qubits-needed compiled-quil))
                            compiled-quil))
    addresses)))
