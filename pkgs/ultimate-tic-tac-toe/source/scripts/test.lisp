;;;; SPDX-License-Identifier: AGPL-3.0-or-later

(require :asdf)

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults *load-truename*))

(defparameter *project-root*
  (truename (merge-pathnames "../" (script-directory))))

(pushnew *project-root* asdf:*central-registry* :test #'equal)

(asdf:load-system :ultimate-tic-tac-toe/test)

(unless (uiop:symbol-call :fiveam '#:run! :ultimate-tic-tac-toe)
  (uiop:quit 1))

(uiop:quit 0)
