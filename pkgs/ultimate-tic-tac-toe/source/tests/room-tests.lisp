;;;; SPDX-License-Identifier: AGPL-3.0-or-later

(in-package #:ultimate-tic-tac-toe.tests)

(defun test-database-path (name)
  (namestring
   (merge-pathnames (format nil "uttt-~A-~A.sqlite3"
                            name
                            (random 1000000000))
                    (uiop:temporary-directory))))

(defmacro with-test-room-store ((path-var name) &body body)
  `(let ((,path-var (test-database-path ,name)))
     (unwind-protect
          (progn
            (ultimate-tic-tac-toe.web::initialize-room-store ,path-var)
            ,@body)
       (ultimate-tic-tac-toe.web::close-room-store)
       (uiop:delete-file-if-exists ,path-var))))

(defun html-includes-p (html text)
  (not (null (search text html :test #'char=))))

(test room-code-normalization-is-forgiving
  (is (equal "ABC2DE"
             (ultimate-tic-tac-toe.web::normalize-game-room-id " ab-c2 de ")))
  (is (equal "98S46R"
             (ultimate-tic-tac-toe.web::normalize-game-room-id "98s 46r")))
  (is (null (ultimate-tic-tac-toe.web::normalize-game-room-id "ABC2D")))
  (is (null (ultimate-tic-tac-toe.web::normalize-game-room-id "ABC2DEF")))
  (is (null (ultimate-tic-tac-toe.web::normalize-game-room-id "ABC1DE"))))

(test standalone-render-keeps-room-entry-points
  (let ((html (ultimate-tic-tac-toe.web::render-game-fragment (make-game))))
    (is (html-includes-p html "action=\"/room/join\""))
    (is (html-includes-p html "action=\"/room/new\""))
    (is (html-includes-p html "hx-post=\"/reset\""))))

(test app-version-defaults-when-unset
  (is (equal "unknown"
             (ultimate-tic-tac-toe.web::configured-version))))

(test room-render-keeps-live-room-contract
  (with-test-room-store (database-path "render")
    (declare (ignore database-path))
    (let* ((room (ultimate-tic-tac-toe.web::create-room))
           (room-id (ultimate-tic-tac-toe.web::game-room-id room)))
      (setf (ultimate-tic-tac-toe.web::game-room-x-player room) "XPLAYER")
      (let ((html (ultimate-tic-tac-toe.web::render-game-fragment
                   (ultimate-tic-tac-toe.web::game-room-game room)
                   :room-id room-id
                   :room room
                   :player :x
                   :poll t)))
        (is (html-includes-p html "has-room"))
        (is (html-includes-p html "is-waiting-room"))
        (is (html-includes-p html (format nil "data-room-id=\"~A\"" room-id)))
        (is (html-includes-p html (format nil "/room/state?id=~A" room-id)))
        (is (html-includes-p html (format nil "/room/events?id=~A" room-id)))
        (is (html-includes-p html "data-live-state=\"syncing\""))
        (is (html-includes-p html "Invite"))
        (is (html-includes-p html "Waiting for O"))))))

(test room-render-marks-post-move-guidance
  (with-test-room-store (database-path "move-render")
    (declare (ignore database-path))
    (let* ((room (ultimate-tic-tac-toe.web::create-room))
           (room-id (ultimate-tic-tac-toe.web::game-room-id room))
           (game (ultimate-tic-tac-toe.web::game-room-game room)))
      (setf (ultimate-tic-tac-toe.web::game-room-x-player room) "XPLAYER"
            (ultimate-tic-tac-toe.web::game-room-o-player room) "OPLAYER")
      (play-move game 0 4)
      (ultimate-tic-tac-toe.web::note-room-change-unlocked room)
      (let ((html (ultimate-tic-tac-toe.web::render-game-fragment
                   game
                   :room-id room-id
                   :room room
                   :player :o
                   :poll t)))
        (is (html-includes-p html "has-last-move"))
        (is (html-includes-p html "is-target-from-last"))
        (is (html-includes-p html "hx-post=\"/room/move\""))
        (is (html-includes-p html "X sent O to the Center board."))))))

(test winning-render-shows-global-win-line
  (let ((game (make-game)))
    (setf (aref (game-board-outcomes game) 0) :x
          (aref (game-board-outcomes game) 1) :x
          (aref (game-board-outcomes game) 2) :x
          (game-winner game) :x)
    (let ((html (ultimate-tic-tac-toe.web::render-game-fragment game)))
      (is (html-includes-p html "global-win-line"))
      (is (html-includes-p html "line-0"))
      (is (html-includes-p html "win-x"))
      (is (html-includes-p html "New game")))))

(test room-store-persists-game-and-seats
  (with-test-room-store (database-path "persist")
    (let* ((room (ultimate-tic-tac-toe.web::create-room))
           (room-id (ultimate-tic-tac-toe.web::game-room-id room)))
      (setf (ultimate-tic-tac-toe.web::game-room-x-player room) "XPLAYER"
            (ultimate-tic-tac-toe.web::game-room-o-player room) "OPLAYER")
      (ultimate-tic-tac-toe.web::note-room-change-unlocked room)
      (play-move (ultimate-tic-tac-toe.web::game-room-game room) 0 4)
      (ultimate-tic-tac-toe.web::persist-room-unlocked room)
      (ultimate-tic-tac-toe.web::close-room-store)
      (ultimate-tic-tac-toe.web::initialize-room-store database-path)
      (let ((restored (ultimate-tic-tac-toe.web::find-room room-id)))
        (is (not (null restored)))
        (is (equal "XPLAYER"
                   (ultimate-tic-tac-toe.web::game-room-x-player restored)))
        (is (equal "OPLAYER"
                   (ultimate-tic-tac-toe.web::game-room-o-player restored)))
        (is (= 1
               (ultimate-tic-tac-toe.web::game-room-version restored)))
        (is (eql :o
                 (game-next-player
                  (ultimate-tic-tac-toe.web::game-room-game restored))))
        (is (eql :x
                 (aref (game-cells
                        (ultimate-tic-tac-toe.web::game-room-game restored))
                       0 4)))))))

(test room-store-prunes-old-rooms-from-disk
  (with-test-room-store (database-path "prune")
    (let* ((room (ultimate-tic-tac-toe.web::create-room))
           (room-id (ultimate-tic-tac-toe.web::game-room-id room)))
      (setf (ultimate-tic-tac-toe.web::game-room-updated-at room)
            (- (get-universal-time)
               ultimate-tic-tac-toe.web::+room-ttl-seconds+
               1))
      (ultimate-tic-tac-toe.web::persist-room-unlocked room)
      (ultimate-tic-tac-toe.web::prune-rooms)
      (is (null (ultimate-tic-tac-toe.web::find-room room-id)))
      (ultimate-tic-tac-toe.web::close-room-store)
      (ultimate-tic-tac-toe.web::initialize-room-store database-path)
      (is (null (ultimate-tic-tac-toe.web::find-room room-id))))))

(test room-store-migrates-room-version-column
  (let ((database-path (test-database-path "migrate")))
    (unwind-protect
         (progn
           (let ((database (sqlite:connect database-path :busy-timeout 5000)))
             (unwind-protect
                  (sqlite:execute-non-query
                   database
                   "create table rooms (
                      id text primary key,
                      game text not null,
                      x_player text,
                      o_player text,
                      created_at integer not null,
                      updated_at integer not null
                    )")
               (sqlite:disconnect database)))
           (ultimate-tic-tac-toe.web::initialize-room-store database-path)
           (let ((room (ultimate-tic-tac-toe.web::create-room)))
             (is (= 0
                    (ultimate-tic-tac-toe.web::game-room-version room)))))
      (ultimate-tic-tac-toe.web::close-room-store)
      (uiop:delete-file-if-exists database-path))))
