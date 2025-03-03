(in-package #:org.shirakumo.radiance.plaster)

(defun call-with-password-protection (function paste &optional (password (post/get "password")))
  (cond ((or (not (eql 3 (dm:field paste "visibility")))
             (string= (dm:field paste "password") (cryptos:pbkdf2-hash password (config :password-salt))))
         (funcall function))
        ((or* password)
         (error 'request-denied :message "The supplied password is incorrect."))
        (T
         (r-clip:process (@template "password.ctml")))))

(defmacro with-password-protection ((paste &optional (password '(post/get "password"))) &body body)
  `(call-with-password-protection
    (lambda () ,@body) ,paste ,password))

(defun render-edit (id)
  (let* ((paste (if id
                    (ensure-paste id)
                    (dm:hull 'pastes)))
         (parent (if id
                     (paste-parent paste)
                     (when (get-var "annotate") (ensure-paste (get-var "annotate"))))))
    (if id
        (check-permission '(edit delete) paste)
        (check-permission 'new))
    (setf (header "X-Robots-Tag") "nofollow")
    (unless id
      (setf (dm:field paste "type") (or* (user:field "plaster-type" (auth:current "anonymous"))
                                         "text")))
    (with-password-protection ((or parent paste))
      (multiple-value-bind (captcha captcha-solution) (generate-captcha)
        (r-clip:process T :paste paste
                          :password (post/get "password")
                          :parent (when parent (dm:id parent))
                          :types *paste-types*
                          :repaste (get-var "repaste")
                          :error (get-var "error")
                          :message (get-var "message")
                          :theme (or* (user:field "plaster-theme" (auth:current "anonymous"))
                                      "default")
                          :captcha captcha
                          :captcha-solution captcha-solution)))))

(defun render-view (id)
  (let* ((paste (ensure-paste id))
         (parent (paste-parent paste)))
    (check-permission 'view paste)
    (setf (header "X-Robots-Tag") "nofollow")
    (if parent
        (redirect (paste-url paste parent))
        (with-password-protection (paste)
          (r-clip:process T :paste paste
                            :password (post/get "password")
                            :annotations (sort (paste-annotations paste)
                                               #'< :key (lambda (a) (dm:field a "time")))
                            :theme (or* (user:field "plaster-theme" (auth:current "anonymous"))
                                        "default"))))))

(defun render-raw (id)
  (let ((paste (ensure-paste id)))
    (check-permission 'view paste)
    (setf (header "X-Robots-Tag") "nofollow")
    (with-password-protection (paste)
      (setf (content-type *response*) "text/plain")
      (dm:field paste "text"))))

(define-page edit "plaster/edit(?:/(.*))?" (:uri-groups (id) :clip "edit.ctml")
  (render-edit id))

(define-page view "plaster/view/(.*)" (:uri-groups (id) :clip "view.ctml")
  (render-view id))

(define-page raw "plaster/view/([^/]*)/raw" (:uri-groups (id))
  (render-raw id))

(define-page edit-new "plaster/^e(?:/(.*))?$" (:uri-groups (id) :clip "edit.ctml")
  (render-edit (when id (from-secure-id id))))

(define-page view-new "plaster/^v/(.*)$" (:uri-groups (id) :clip "view.ctml")
  (render-view (from-secure-id id)))

(define-page raw-new "plaster/^v/([^/]*)/raw$" (:uri-groups (id))
  (render-raw (from-secure-id id)))

(define-page list "plaster/list(?:/(.*))?" (:uri-groups (page) :clip "list.ctml")
  (check-permission 'list)
  (setf (header "X-Robots-Tag") "nofollow")
  (let* ((page (or (when page (parse-integer page :junk-allowed T)) 0))
         (pastes (dm:get 'pastes (db:query (:= 'visibility 1))
                         :sort '((time :DESC))
                         :skip (* page (config :pastes-per-page))
                         :amount (config :pastes-per-page))))
    (r-clip:process T :pastes pastes
                      :page page
                      :has-more (<= (config :pastes-per-page) (length pastes)))))

(define-page user "plaster/user/([^/]*)(?:/(.*))?" (:uri-groups (username page) :clip "user.ctml")
  (check-permission 'user)
  (setf (header "X-Robots-Tag") "nofollow")
  (let* ((page (or (when page (parse-integer page :junk-allowed T)) 0))
         (user (user:get username)))
    (unless user
      (error 'request-not-found :message (format NIL "No such user ~s." username)))
    (let ((pastes (dm:get 'pastes
                          (if (and (auth:current) (or (eql (auth:current) user)
                                                      (user:check (auth:current) '(perm plaster))))
                              (db:query (:= 'author username))
                              (db:query (:and (:= 'author username)
                                              (:= 'visibility 1))))
                          :sort '((time :DESC))
                          :skip (* page (config :pastes-per-page))
                          :amount (config :pastes-per-page))))
      (r-clip:process T :pastes pastes
                        :user user
                        :username (user:username user)
                        :page page
                        :has-more (<= (config :pastes-per-page) (length pastes))))))

(profile:define-panel pastes (:user user :clip "user-panel.ctml")
  (let ((pastes (dm:get 'pastes
                        (if (and (auth:current) (or (eql (auth:current) user)
                                                    (user:check (auth:current) '(perm plaster))))
                            (db:query (:= 'author (user:username user)))
                            (db:query (:and (:= 'author (user:username user))
                                            (:= 'visibility 1))))
                        :sort '((time :DESC))
                        :amount (config :pastes-per-page))))
    (r-clip:process T :pastes pastes)))

(define-implement-trigger admin
  (admin:define-panel settings plaster (:clip "admin-panel.ctml")
    (with-actions (error info)
        ((:save
          (setf (user:field "plaster-type" (auth:current)) (post/get "type"))
          (setf (user:field "plaster-theme" (auth:current)) (post/get "theme"))
          (setf info "Editor preferences saved.")))
      (r-clip:process T :types *paste-types*
                        :themes *paste-themes*
                        :type (or* (user:field "plaster-type" (auth:current)) "text")
                        :theme (or* (user:field "plaster-theme" (auth:current)) "default")
                        :error error :info info))))

(define-page frontpage "plaster/^$" ()
  (redirect #@"plaster/edit"))

(define-page no-robots "plaster/robots.txt" ()
  "User-agent: *
Disallow: /")
