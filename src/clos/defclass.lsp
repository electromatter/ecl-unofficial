;;;;  Copyright (c) 1992, Giuseppe Attardi.
;;;;
;;;;    This program is free software; you can redistribute it and/or
;;;;    modify it under the terms of the GNU Library General Public
;;;;    License as published by the Free Software Foundation; either
;;;;    version 2 of the License, or (at your option) any later version.
;;;;
;;;;    See file '../Copyright' for full details.

(in-package "CLOS")

;;; ----------------------------------------------------------------------
;;; DEFCLASS

(defun make-function-initform (initform)
  (if (constantp initform) initform `#'(lambda () ,initform)))

(defun parse-default-initargs (default-initargs)
  (declare (si::c-local))
  (do* ((output-list nil)
	(scan default-initargs (cddr scan))
	(already-supplied '()))
       ((endp scan) `(list ,@(nreverse output-list)))
    (when (endp (rest scan))
      (si::simple-program-error "Wrong number of elements in :DEFAULT-INITARGS option."))
    (let ((slot-name (first scan))
	  (initform (second scan)))
      (if (member slot-name already-supplied)
	  (si::simple-program-error "~S is duplicated in :DEFAULT-INITARGS form ~S"
				    slot-name default-initargs)
	  (push slot-name already-supplied))
      (push `(list ',slot-name ',initform ,(make-function-initform initform))
	    output-list))))

(defmacro defclass (&whole form &rest args)
  (declare (si::c-local))
  (let* (name superclasses slots options
	 metaclass-name default-initargs documentation
	 (processed-options '())
	 options)
    (unless (>= (length args) 3)
      (si::simple-program-error "Illegal defclass form: the class name, the superclasses and the slots should always be provided"))
    (setq name (first args)
	  superclasses (second args)
	  slots (third args)
	  args (cdddr args))
    (unless (and (listp superclasses) (listp slots))
      (si::simple-program-error "Illegal defclass form: superclasses and slots should be lists"))
    (unless (and (symbolp name) (every #'symbolp superclasses))
      (si::simple-program-error "Illegal defclass form: superclasses and class name are not valid"))
    ;;
    ;; Here we compose the final form. The slots list, and the default initargs
    ;; may contain object that need to be evaluated. Hence, it cannot be always
    ;; quoted.
    ;;
    (do ((l (setf slots (parse-slots slots)) (rest l)))
	((endp l)
	 (setf slots
	       (if (every #'constantp slots)
		   (list 'quote (mapcar #'second slots))
		   `(list ,@slots))))
      (let* ((slotd (first l))
	     (initform (slotd-initform slotd)))
	(if (constantp initform)
	    (setf (slotd-initform slotd) (si::maybe-unquote initform)
	          slotd (list 'quote slotd))
	    (setf slotd (mapcar #'(lambda (x) `',x) slotd)
		  (slotd-initform slotd) (make-function-initform initform)
		  slotd (list* 'list slotd)))
	(setf (first l) slotd)))
    (dolist (option args)
      (let ((option-name (first option)))
	(if (member option-name processed-options)
	    (si:simple-program-error
	     "Option ~s for DEFCLASS specified more than once"
	     option-name)
	    (push option-name processed-options))
	(setq option-value
	      (case option-name
		((:metaclass :documentation)
		 (list 'quote (second option)))
		(:default-initargs
		 (setf option-name :direct-default-initargs)
		 (parse-default-initargs (rest option)))
		(otherwise
		 (si:simple-program-error "~S is not a valid DEFCLASS option"
					  option-name))))
	(setf options (list* option-name option-value options))))
    `(eval-when (compile load eval)
      (ensure-class ',name :direct-superclasses ',superclasses
       :direct-slots ,slots ,@options))))

;;; ----------------------------------------------------------------------
;;; ENSURE-CLASS
;;;
(defun ensure-class (name &rest initargs)
  (setf class (apply #'ensure-class-using-class (find-class name nil) name
		     initargs))
  (when name (setf (find-class name) class)))
(eval-when (compile)
  (defun ensure-class (name &rest initargs)
    (warn "Ignoring definition for class ~S" name)))

;;; ----------------------------------------------------------------------
;;; support for standard-class

(defun compute-clos-class-precedence-list (class-name superclasses)
  ;; We start by computing two values.
  ;;   CPL
  ;;     The depth-first left-to-right up to joins walk of the supers tree.
  ;;     This is equivalent to depth-first right-to-left walk of the
  ;;     tree with all but the last occurence of a class removed from
  ;;     the resulting list.  This is in fact how the walk is implemented.
  ;;
  ;;   PRECEDENCE-ALIST
  ;;     An alist of the precedence relations. The car of each element
  ;;     of the precedence-alist is a class C, the cdr is all the classes C'
  ;;     which should precede C because either:
  ;;       C is a local super of C'
  ;;      or
  ;;       C' appears before C in some class's local-supers.
  ;;
  ;;     Thus, the precedence-alist reflects the two constraints that:
  ;;       1. A class must appear in the CPL before its local supers.
  ;;       2. Order of local supers is preserved in the CPL.
  ;;
  (labels
   ((must-move-p (element list precedence-alist &aux move)
		 (dolist (must-precede (cdr (assoc element
						   precedence-alist
						   :test #'eq)))
			 (when (setq move (member must-precede (cdr list)
						  :test #'eq))
			       (return move))))
    (find-farthest-move
     (element move precedence-alist)
     (dolist (must-precede (transitive-closure element precedence-alist))
	     (setq move (or (member must-precede move :test #'eq) move)))
     move)
    (transitive-closure
     (class precedence-alist)
     (let* ((closure ()))
       (labels ((walk (element path)
		      (when (member element path :test #'eq)
			    (class-ordering-error
			     class-name element path precedence-alist))
		      (dolist (precede
			       (cdr (assoc element
					   precedence-alist :test #'eq)))
			      (unless (member precede closure :test #'eq)
				      (pushnew precede closure)
				      (walk precede (cons element path))))))
	       (walk class nil)
	       closure))))

   (multiple-value-bind
    (cpl precedence-alist)
    (walk-supers superclasses nil nil)
    (let* ((tail cpl)
	   (element nil)
	   (move nil))
      ;; For each class in the cpl, make sure that there are no classes after
      ;; it which should be before it.  We do this by cdring down the list,
      ;; making sure that for each element of the list, none of its
      ;; must-precedes come after it in the list. If we find one, we use the
      ;; transitive closure of the must-precedes (call find-farthest-move) to
      ;; see where the class must really be moved. We use a hand-coded loop
      ;; so that we can splice things in and out of the CPL as we go.
      (loop (when (null tail) (return))
	    (setq element (car tail)
		  move (must-move-p element tail precedence-alist))
	    (cond (move
		   (setq move (find-farthest-move element move precedence-alist))
		   (setf (cdr move) (cons element (cdr move)))
		   (setf (car tail) (cadr tail))
		   (setf (cdr tail) (cddr tail))
		   )
		  (t
		   (setq tail (cdr tail)))))
      cpl))))

(defun walk-supers (supers cpl precedence-alist)
  (declare (si::c-local))
  (do* ((pre (reverse supers))
	(sup)
	(precedence))
       ((null pre) (values cpl precedence-alist))
    (setq sup (pop pre))
    (when pre
      (if (setq precedence (assoc sup precedence-alist :test #'eq))
	  ;; don't use rplacd here:
	  (setq precedence (cons (car precedence) (union pre precedence)))
	  (push (cons sup pre) precedence-alist)))
    (multiple-value-setq (cpl precedence-alist)
      (walk-supers (class-direct-superclasses sup) cpl precedence-alist))
    (setq cpl (adjoin sup cpl))))

(defun class-ordering-error (root element path precedence-alist)
  (declare (si::c-local))
  (setq path (cons element (reverse (member element (reverse path) :test #'eq))))
  (flet ((pretty (class) (or (class-name class) class)))
    (let ((explanations ()))
      (do ((tail path (cdr tail)))
	  ((null (cdr tail)))
	(let* ((after (cadr tail))
	       (before (car tail)))
	  (if (member after (class-direct-superclasses before) :test #'eq)
	      (push (format nil
			    "~% ~A must precede ~A -- ~
                              ~A is in the local supers of ~A."
			    (pretty before) (pretty after)
			    (pretty after) (pretty before))
		    explanations)
	      (dolist (common-precede
			(intersection
			  (cdr (assoc after precedence-alist :test #'eq))
			  (cdr (assoc before precedence-alist :test #'eq))))
		(when (member after (member before
					    (class-direct-superclasses common-precede)
					    :test #'eq)
			      :test #'eq)
		  (push (format nil
				"~% ~A must precede ~A -- ~
                                  ~A has local supers ~S."
				(pretty before) (pretty after)
				(pretty common-precede)
				(mapcar #'pretty
					(class-direct-superclasses common-precede)))
			explanations))))))
      (error "While computing the class-precedence-list for the class ~A:~%~
              There is a circular constraint through the classes:~{ ~A~}.~%~
              This arises because:~{~A~}"
	     root
	     (mapcar #'pretty path)
	     (reverse explanations)))))

;;; ----------------------------------------------------------------------
