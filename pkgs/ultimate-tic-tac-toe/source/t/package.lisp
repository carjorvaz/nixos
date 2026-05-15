;;;; SPDX-License-Identifier: AGPL-3.0-or-later

(defpackage #:ultimate-tic-tac-toe.tests
  (:use #:cl #:fiveam)
  (:import-from #:ultimate-tic-tac-toe.game
                #:make-game
                #:game-cells
                #:game-board-outcomes
                #:game-next-player
                #:game-active-board
                #:game-winner
                #:board-outcome
                #:board-winning-line
                #:global-winning-line
                #:legal-move-p
                #:play-move))
