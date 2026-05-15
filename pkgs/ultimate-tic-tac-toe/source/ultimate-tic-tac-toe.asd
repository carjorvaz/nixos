;;;; SPDX-License-Identifier: AGPL-3.0-or-later

(asdf:defsystem "ultimate-tic-tac-toe"
  :description "Server-rendered Ultimate Tic Tac Toe with HTMX."
  :author "Contributors"
  :license "AGPL-3.0-or-later"
  :version "0.1.0"
  :depends-on ("bordeaux-threads" "hunchentoot" "cl-who")
  :serial t
  :components ((:file "src/package")
               (:file "src/game")
               (:file "src/web")))

(asdf:defsystem "ultimate-tic-tac-toe/test"
  :description "Tests for ultimate-tic-tac-toe."
  :author "Contributors"
  :license "AGPL-3.0-or-later"
  :depends-on ("ultimate-tic-tac-toe" "fiveam")
  :serial t
  :components ((:file "t/package")
               (:file "t/game-tests"))
  :perform (asdf:test-op (operation component)
             (declare (ignore operation component))
             (unless (uiop:symbol-call :fiveam '#:run! :ultimate-tic-tac-toe)
               (error "The ultimate-tic-tac-toe test suite failed."))))
