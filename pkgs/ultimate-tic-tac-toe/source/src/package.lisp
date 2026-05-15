;;;; SPDX-License-Identifier: AGPL-3.0-or-later

(defpackage #:ultimate-tic-tac-toe.game
  (:use #:cl)
  (:export
   #:make-game
   #:game
   #:game-cells
   #:game-board-outcomes
   #:game-next-player
   #:game-active-board
   #:game-winner
   #:game-move-count
   #:game-last-move
   #:board-outcome
   #:board-winning-line
   #:global-winning-line
   #:mark-at
   #:legal-move-p
   #:available-board-p
   #:play-move
   #:game-snapshot
   #:game-from-snapshot
   #:game-over-p
   #:player-label
   #:outcome-label))

(defpackage #:ultimate-tic-tac-toe.web
  (:use #:cl)
  (:import-from #:ultimate-tic-tac-toe.game
                #:make-game
                #:game-next-player
                #:game-active-board
                #:game-winner
                #:game-last-move
                #:board-outcome
                #:board-winning-line
                #:global-winning-line
                #:mark-at
                #:legal-move-p
                #:available-board-p
                #:play-move
                #:game-snapshot
                #:game-from-snapshot
                #:game-over-p
                #:player-label
                #:outcome-label)
  (:export
   #:start
   #:stop
   #:server-port))
