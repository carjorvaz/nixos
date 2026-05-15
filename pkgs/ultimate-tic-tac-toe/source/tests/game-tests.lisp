;;;; SPDX-License-Identifier: AGPL-3.0-or-later

(in-package #:ultimate-tic-tac-toe.tests)

(def-suite :ultimate-tic-tac-toe)
(in-suite :ultimate-tic-tac-toe)

(test new-game-starts-open
  (let ((game (make-game)))
    (is (eql :x (game-next-player game)))
    (is (null (game-active-board game)))
    (is (legal-move-p game 0 0))
    (is (legal-move-p game 8 8))))

(test accepted-move-selects-target-board
  (let ((game (make-game)))
    (multiple-value-bind (updated-game acceptedp)
        (play-move game 0 4)
      (is (eq updated-game game))
      (is (not (null acceptedp))))
    (is (eql :o (game-next-player game)))
    (is (= 4 (game-active-board game)))
    (is (not (legal-move-p game 0 1)))
    (is (legal-move-p game 4 1))))

(test completed-target-board-opens-the-choice
  (let ((game (make-game)))
    (setf (aref (game-board-outcomes game) 4) :draw)
    (multiple-value-bind (updated-game acceptedp)
        (play-move game 0 4)
      (is (eq updated-game game))
      (is (not (null acceptedp))))
    (is (null (game-active-board game)))))

(test local-board-win-is-recorded
  (let ((game (make-game)))
    (setf (aref (game-cells game) 2 0) :x
          (aref (game-cells game) 2 1) :x
          (game-active-board game) nil
          (game-next-player game) :x)
    (multiple-value-bind (updated-game acceptedp)
        (play-move game 2 2)
      (is (eq updated-game game))
      (is (not (null acceptedp))))
    (is (eql :x (board-outcome game 2)))
    (is (= 0 (board-winning-line game 2)))
    (is (not (legal-move-p game 2 3)))))

(test global-win-is-recorded
  (let ((game (make-game)))
    (setf (aref (game-board-outcomes game) 0) :x
          (aref (game-board-outcomes game) 1) :x
          (aref (game-cells game) 2 0) :x
          (aref (game-cells game) 2 1) :x
          (game-active-board game) nil
          (game-next-player game) :x)
    (multiple-value-bind (updated-game acceptedp)
        (play-move game 2 2)
      (is (eq updated-game game))
      (is (not (null acceptedp))))
    (is (eql :x (game-winner game)))))

(test global-winning-line-is-recorded
  (let ((game (make-game)))
    (setf (aref (game-board-outcomes game) 0) :o
          (aref (game-board-outcomes game) 4) :o
          (aref (game-board-outcomes game) 8) :o
          (game-winner game) :o)
    (is (= 6 (global-winning-line game)))))

(test game-snapshot-round-trips
  (let ((game (make-game)))
    (play-move game 0 4)
    (play-move game 4 8)
    (let ((restored (game-from-snapshot (game-snapshot game))))
      (is (eql (game-next-player game) (game-next-player restored)))
      (is (= (game-active-board game) (game-active-board restored)))
      (is (= (game-move-count game) (game-move-count restored)))
      (is (eql :x (aref (game-cells restored) 0 4)))
      (is (eql :o (aref (game-cells restored) 4 8))))))
