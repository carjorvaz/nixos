;;;; SPDX-License-Identifier: AGPL-3.0-or-later

(require :asdf)

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults *load-truename*))

(defparameter *project-root*
  (truename (merge-pathnames "../" (script-directory))))

(pushnew *project-root* asdf:*central-registry* :test #'equal)

(asdf:load-system :ultimate-tic-tac-toe)

(defun configured-port ()
  (let ((raw (uiop:getenv "PORT")))
    (if raw
        (parse-integer raw :junk-allowed nil)
        4242)))

(defun configured-address ()
  (or (uiop:getenv "HOST")
      "127.0.0.1"))

(let ((address (configured-address))
      (port (configured-port)))
  (ultimate-tic-tac-toe.web:start :address address :port port)
  (format t "~&Ultimate Tic Tac Toe listening on http://~A:~D/~%" address port)
  (finish-output)
  (loop (sleep 3600)))
