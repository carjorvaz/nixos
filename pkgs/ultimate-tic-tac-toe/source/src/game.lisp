;;;; SPDX-License-Identifier: AGPL-3.0-or-later

(in-package #:ultimate-tic-tac-toe.game)

(defconstant +board-count+ 9)

(defparameter +winning-lines+
  '((0 1 2)
    (3 4 5)
    (6 7 8)
    (0 3 6)
    (1 4 7)
    (2 5 8)
    (0 4 8)
    (2 4 6)))

(defstruct (game (:constructor make-game))
  (cells (make-array (list +board-count+ +board-count+) :initial-element nil))
  (board-outcomes (make-array +board-count+ :initial-element nil))
  (next-player :x)
  (active-board nil)
  (winner nil)
  (move-count 0))

(defun player-p (value)
  (or (eql value :x)
      (eql value :o)))

(defun player-label (player)
  (ecase player
    (:x "X")
    (:o "O")))

(defun outcome-label (outcome)
  (cond
    ((eql outcome :x) "X")
    ((eql outcome :o) "O")
    ((eql outcome :draw) "Draw")
    ((null outcome) "Open")
    (t "Open")))

(defun other-player (player)
  (ecase player
    (:x :o)
    (:o :x)))

(defun valid-index-p (value)
  (and (integerp value)
       (<= 0 value)
       (< value +board-count+)))

(defun mark-at (game board cell)
  (when (and (valid-index-p board)
             (valid-index-p cell))
    (aref (game-cells game) board cell)))

(defun board-outcome (game board)
  (when (valid-index-p board)
    (aref (game-board-outcomes game) board)))

(defun board-complete-p (game board)
  (not (null (board-outcome game board))))

(defun line-owner-and-index (getter)
  (loop for (first second third) in +winning-lines+
        for line-index from 0
        for owner = (funcall getter first)
        when (and (player-p owner)
                  (eql owner (funcall getter second))
                  (eql owner (funcall getter third)))
          return (values owner line-index)))

(defun line-owner (getter)
  (line-owner-and-index getter))

(defun all-positions-filled-p (getter)
  (loop for index below +board-count+
        always (funcall getter index)))

(defun local-board-outcome (game board)
  (let ((getter (lambda (cell)
                  (aref (game-cells game) board cell))))
    (or (line-owner getter)
        (when (all-positions-filled-p getter)
          :draw))))

(defun board-winning-line (game board)
  (when (and (valid-index-p board)
             (player-p (board-outcome game board)))
    (let ((getter (lambda (cell)
                    (aref (game-cells game) board cell))))
      (nth-value 1 (line-owner-and-index getter)))))

(defun global-outcome (game)
  (let ((getter (lambda (board)
                  (let ((outcome (board-outcome game board)))
                    (when (player-p outcome)
                      outcome)))))
    (or (line-owner getter)
        (when (loop for board below +board-count+
                    always (board-outcome game board))
          :draw))))

(defun global-winning-line (game)
  (when (player-p (game-winner game))
    (let ((getter (lambda (board)
                    (let ((outcome (board-outcome game board)))
                      (when (player-p outcome)
                        outcome)))))
      (nth-value 1 (line-owner-and-index getter)))))

(defun available-board-p (game board)
  (and (valid-index-p board)
       (null (game-winner game))
       (not (board-complete-p game board))
       (or (null (game-active-board game))
           (= board (game-active-board game)))))

(defun legal-move-p (game board cell)
  (and (available-board-p game board)
       (valid-index-p cell)
       (null (mark-at game board cell))))

(defun update-outcomes-after-move (game board)
  (setf (aref (game-board-outcomes game) board)
        (local-board-outcome game board))
  (setf (game-winner game)
        (global-outcome game)))

(defun play-move (game board cell)
  "Apply BOARD/CELL for the current player.

Returns two values: GAME and a generalized boolean indicating whether the move
was accepted. GAME is mutated in place so it can live directly in a web session."
  (unless (legal-move-p game board cell)
    (return-from play-move (values game nil)))
  (setf (aref (game-cells game) board cell)
        (game-next-player game))
  (incf (game-move-count game))
  (update-outcomes-after-move game board)
  (unless (game-winner game)
    (setf (game-active-board game)
          (unless (board-complete-p game cell)
            cell))
    (setf (game-next-player game)
          (other-player (game-next-player game))))
  (values game t))

(defun game-snapshot (game)
  (list :cells (loop for board below +board-count+
                     collect (loop for cell below +board-count+
                                   collect (aref (game-cells game) board cell)))
        :board-outcomes (loop for board below +board-count+
                              collect (aref (game-board-outcomes game) board))
        :next-player (game-next-player game)
        :active-board (game-active-board game)
        :winner (game-winner game)
        :move-count (game-move-count game)))

(defun game-from-snapshot (snapshot)
  (let ((game (make-game)))
    (loop for board below +board-count+
          for row in (getf snapshot :cells)
          do (loop for cell below +board-count+
                   for mark in row
                   do (setf (aref (game-cells game) board cell) mark)))
    (loop for board below +board-count+
          for outcome in (getf snapshot :board-outcomes)
          do (setf (aref (game-board-outcomes game) board) outcome))
    (setf (game-next-player game) (getf snapshot :next-player)
          (game-active-board game) (getf snapshot :active-board)
          (game-winner game) (getf snapshot :winner)
          (game-move-count game) (getf snapshot :move-count 0))
    game))

(defun game-over-p (game)
  (not (null (game-winner game))))
