#|
 This file is a part of Purplish
 (c) 2016 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.radiance.plaster)

(defun api-paste-output (paste)
  (cond ((string= "true" (post/get "browser"))
         (redirect (paste-url paste)))
        (T
         (api-output (reformat-paste paste)))))

(define-api plaster/view (id &optional current-password include-annotations) ()
  (let ((paste (ensure-paste id)))
    (check-permission 'view paste)
    (with-password-protection (paste current-password)
      (api-output (reformat-paste paste :include-annotations (or* include-annotations))))))

(define-api plaster/list (&optional author skip amount include-annotations) ()
  (check-permission 'list)
  (let ((amount (if amount (parse-integer amount) (config :api :default-amount)))
        (skip (if skip (parse-integer skip) 0)))
    (unless (<= 0 amount (config :api :maximum-amount))
      (error 'api-argument-invalid :argument "amount"
                                   :message (format NIL "Amount must be within [0,~a]" amount)))
    (let ((query (cond ((and (auth:current) (equalp author (user:username (auth:current))))
                        (db:query (:= 'author author)))
                       (author
                        (db:query (:and (:= 'visibility 1)
                                        (:= 'author author))))
                       (T
                        (db:query (:= 'visibility 1))))))
      (api-output
       (loop for paste in (dm:get 'plaster-pastes query
                                  :sort '((time :DESC))
                                  :amount amount
                                  :skip skip)
             collect (reformat-paste paste :include-annotations include-annotations))))))

(rate:define-limit create (time-left :limit 2)
  (error 'api-error :message (format NIL "Please wait ~a second~:p before pasting again."
                                     time-left)))

(define-api plaster/new (text &optional title type parent visibility password current-password) ()
  (rate:with-limitation (create)
    (check-permission 'new)
    (when parent (check-password parent current-password))
    (let ((paste (create-paste text :title title
                                    :type type
                                    :parent parent
                                    :visibility visibility
                                    :password password
                                    :author (user:username (or (auth:current) (user:get "anonymous"))))))
      (api-paste-output paste))))

(define-api plaster/edit (id &optional text type title visibility password current-password) ()
  (let ((paste (ensure-paste id)))
    (check-permission 'edit paste)
    (check-password paste current-password)
    (edit-paste id :text text :title title :type type :visibility visibility :password password)
    (api-paste-output paste)))

(define-api plaster/delete (id &optional current-password) ()
  (let ((paste (ensure-paste id)))
    (check-permission 'delete paste)
    (check-password paste current-password)
    (delete-paste paste)
    (if (string= "true" (post/get "browser"))
        (redirect (uri-to-url "plaster/edit"
                              :representation :external
                              :query '(("message" . "Paste deleted"))))
        (api-output `(("_id" . ,(dm:id paste)))))))
