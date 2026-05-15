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

(test room-store-persists-game-and-seats
  (with-test-room-store (database-path "persist")
    (let* ((room (ultimate-tic-tac-toe.web::create-room))
           (room-id (ultimate-tic-tac-toe.web::game-room-id room)))
      (setf (ultimate-tic-tac-toe.web::game-room-x-player room) "XPLAYER"
            (ultimate-tic-tac-toe.web::game-room-o-player room) "OPLAYER")
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
