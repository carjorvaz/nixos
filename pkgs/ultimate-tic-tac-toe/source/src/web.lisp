;;;; SPDX-License-Identifier: AGPL-3.0-or-later

(in-package #:ultimate-tic-tac-toe.web)

(defparameter *acceptor* nil)
(defparameter *rooms* (make-hash-table :test #'equal))
(defparameter *rooms-lock* (bordeaux-threads:make-lock "ultimate-tic-tac-toe rooms"))
(defparameter +room-code-alphabet+ "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
(defparameter +room-code-length+ 6)
(defparameter +room-ttl-seconds+ (* 18 60 60))

(defstruct (game-room (:constructor make-game-room))
  id
  game
  x-player
  o-player
  created-at
  updated-at)

(defun configure-session-secret ()
  (let ((secret (uiop:getenv "SESSION_SECRET")))
    (cond
      ((and secret (plusp (length secret)))
       (setf hunchentoot:*session-secret* secret))
      ((not (boundp 'hunchentoot:*session-secret*))
       (hunchentoot:reset-session-secret)))))

(defun seed-random-state ()
  (setf *random-state* (make-random-state t)))

(defun css-classes (&rest names)
  (format nil "~{~A~^ ~}" (remove nil names)))

(defun system-path (relative-path)
  (merge-pathnames relative-path
                   (asdf:system-source-directory :ultimate-tic-tac-toe)))

(defun handle-asset (relative-path content-type)
  (setf (hunchentoot:content-type*) content-type)
  (hunchentoot:handle-static-file (namestring (system-path relative-path))))

(defun parse-index (value)
  (handler-case
      (let ((index (parse-integer value :junk-allowed nil)))
        (when (and (<= 0 index)
                   (< index 9))
          index))
    (error () nil)))

(defun room-id-path (game-room-id)
  (format nil "/room?id=~A" game-room-id))

(defun room-state-path (game-room-id)
  (format nil "/room/state?id=~A" game-room-id))

(defun redirect-see-other (path)
  (setf (hunchentoot:header-out :location) path
        (hunchentoot:return-code*) hunchentoot:+http-see-other+)
  (hunchentoot:abort-request-handler))

(defun normalize-game-room-id (game-room-id)
  (when (and game-room-id (plusp (length game-room-id)))
    (string-upcase
     (string-trim '(#\Space #\Tab #\Newline #\Return) game-room-id))))

(defun random-token (&optional (length +room-code-length+))
  (let ((alphabet-length (length +room-code-alphabet+)))
    (coerce
     (loop repeat length
           collect (aref +room-code-alphabet+
                         (random alphabet-length)))
     'string)))

(defun fresh-game-room-id ()
  (loop repeat 128
        for game-room-id = (random-token)
        unless (gethash game-room-id *rooms*)
          return game-room-id
        finally (error "Could not make a room id.")))

(defun prune-rooms ()
  (let ((oldest (- (get-universal-time) +room-ttl-seconds+)))
    (maphash (lambda (game-room-id room)
               (when (< (game-room-updated-at room) oldest)
                 (remhash game-room-id *rooms*)))
             *rooms*)))

(defun create-room ()
  (bordeaux-threads:with-lock-held (*rooms-lock*)
    (prune-rooms)
    (let* ((now (get-universal-time))
           (game-room-id (fresh-game-room-id))
           (room (make-game-room :id game-room-id
                                  :game (make-game)
                                  :created-at now
                                  :updated-at now)))
      (setf (gethash game-room-id *rooms*) room)
      room)))

(defun find-room (game-room-id)
  (let ((normalized-id (normalize-game-room-id game-room-id)))
    (when normalized-id
      (bordeaux-threads:with-lock-held (*rooms-lock*)
        (gethash normalized-id *rooms*)))))

(defun visitor-id ()
  (hunchentoot:start-session)
  (or (hunchentoot:session-value :visitor-id)
      (setf (hunchentoot:session-value :visitor-id)
            (random-token 18))))

(defun claim-room-player (room)
  (let ((visitor-id (visitor-id)))
    (bordeaux-threads:with-lock-held (*rooms-lock*)
      (cond
        ((or (null (game-room-x-player room))
             (equal visitor-id (game-room-x-player room)))
         (setf (game-room-x-player room) visitor-id)
         :x)
        ((or (null (game-room-o-player room))
             (equal visitor-id (game-room-o-player room)))
         (setf (game-room-o-player room) visitor-id)
         :o)
        (t :spectator)))))

(defun playable-player-p (player)
  (or (eql player :x)
      (eql player :o)))

(defun player-seat-label (player)
  (case player
    (:x "X")
    (:o "O")
    (:spectator "Watch")
    (otherwise "-")))

(defun player-turn-p (game player)
  (or (null player)
      (and (playable-player-p player)
           (eql player (game-next-player game)))))

(defmacro with-room-locked ((room) &body body)
  `(bordeaux-threads:with-lock-held (*rooms-lock*)
     (setf (game-room-updated-at ,room) (get-universal-time))
     ,@body))

(defun current-game ()
  (hunchentoot:start-session)
  (or (hunchentoot:session-value :game)
      (setf (hunchentoot:session-value :game)
            (make-game))))

(defun replace-current-game ()
  (hunchentoot:start-session)
  (setf (hunchentoot:session-value :game)
        (make-game)))

(defun mark-asset (mark)
  (ecase mark
    (:x "/x.svg")
    (:o "/o.svg")))

(defun board-position-label (board)
  (aref #("Top left"
          "Top"
          "Top right"
          "Left"
          "Center"
          "Right"
          "Bottom left"
          "Bottom"
          "Bottom right")
        board))

(defun target-label (game)
  (cond
    ((game-winner game) "Done")
    ((game-active-board game)
     (format nil "~A board" (board-position-label (game-active-board game))))
    (t "Any open board")))

(defun result-label (game)
  (let ((winner (game-winner game)))
    (cond
      ((eql winner :x) "X wins")
      ((eql winner :o) "O wins")
      ((eql winner :draw) "Draw")
      (t (format nil "~A to move"
                 (player-label (game-next-player game)))))))

(defun player-label-p (value)
  (or (eql value :x)
      (eql value :o)))

(defparameter +line-boards+
  #((0 1 2)
    (3 4 5)
    (6 7 8)
    (0 3 6)
    (1 4 7)
    (2 5 8)
    (0 4 8)
    (2 4 6)))

(defun global-winning-board-p (game board)
  (let ((line (global-winning-line game)))
    (and line
         (find board (aref +line-boards+ line) :test #'=))))

(defun cell-aria-label (game board cell)
  (format nil "Play ~A in board ~D cell ~D"
          (player-label (game-next-player game))
          (1+ board)
          (1+ cell)))

(defun emit-mark (stream mark)
  (cl-who:with-html-output (stream)
    (:img :class (css-classes "mark"
                              (format nil "mark-~(~A~)" mark))
          :src (mark-asset mark)
          :alt (player-label mark))))

(defun emit-cell (stream game board cell &key room-id player)
  (let ((mark (mark-at game board cell))
        (legalp (and (legal-move-p game board cell)
                     (player-turn-p game player))))
    (cl-who:with-html-output (stream)
      (:div :class (css-classes "micro-cell"
                                (when mark "is-filled")
                                (when legalp "is-playable"))
        (cond
          (mark
           (emit-mark stream mark))
          (legalp
           (cl-who:htm
            (:form :class "cell-form"
                   :method "post"
                   :action (if room-id "/room/move" "/move")
                   :hx-post (if room-id "/room/move" "/move")
                   :hx-target "#game"
                   :hx-swap "outerHTML"
              (when room-id
                (cl-who:htm
                 (:input :type "hidden"
                         :name "id"
                         :value room-id)))
              (:input :type "hidden"
                      :name "board"
                      :value board)
              (:input :type "hidden"
                      :name "cell"
                      :value cell)
              (:button :class "cell-button"
                       :type "submit"
                       :aria-label (cell-aria-label game board cell)
                (:span :class "cell-dot"
                       :aria-hidden "true")))))
          (t
           (cl-who:htm
            (:span :class "cell-blank"
                   :aria-hidden "true"))))))))

(defun emit-local-board (stream game board &key room-id player)
  (let ((outcome (board-outcome game board)))
    (cl-who:with-html-output (stream)
      (:section :class (css-classes "local-board"
                                    (when (available-board-p game board)
                                      "is-available")
                                    (when (and (available-board-p game board)
                                               (null (game-active-board game)))
                                      "is-choice")
                                    (when (and (game-active-board game)
                                               (= board (game-active-board game)))
                                      "is-active")
                                    (when (eql outcome :x) "is-won-x")
                                    (when (eql outcome :o) "is-won-o")
                                    (when (eql outcome :draw) "is-draw")
                                    (when (global-winning-board-p game board)
                                      "is-global-win-board"))
                :aria-label (format nil "Board ~D, ~A"
                                    (1+ board)
                                    (outcome-label outcome))
        (:div :class "micro-grid"
          (loop for cell below 9
                do (emit-cell stream game board cell
                              :room-id room-id
                              :player player))
          (when (player-label-p outcome)
            (cl-who:htm
             (:img :class (css-classes "board-win-glyph"
                                       (when (eql outcome :x) "win-x")
                                       (when (eql outcome :o) "win-o"))
                   :src (mark-asset outcome)
                   :alt ""
                   :aria-hidden "true"))))))))

(defun emit-confetti (stream game)
  (when (player-label-p (game-winner game))
    (cl-who:with-html-output (stream)
      (:div :class "confetti"
            :aria-hidden "true"
        (loop for index below 14
              do (cl-who:htm
                  (:span :class (format nil "confetti-piece piece-~D" index))))))))

(defun emit-actions (stream room-id)
  (cl-who:with-html-output (stream)
    (:div :class "action-forms"
      (if room-id
          (cl-who:htm
           (:button :class "reset-button secondary-button"
                    :type "button"
                    :onclick "navigator.clipboard && navigator.clipboard.writeText(window.location.href)"
                    "Copy")
           (:form :class "reset-form"
                  :method "post"
                  :action "/room/reset"
                  :hx-post "/room/reset"
                  :hx-target "#game"
                  :hx-swap "outerHTML"
             (:input :type "hidden"
                     :name "id"
                     :value room-id)
             (:button :class "reset-button"
                      :type "submit"
                      "New")))
          (cl-who:htm
           (:form :class "reset-form"
                  :method "post"
                  :action "/room/new"
             (:button :class "reset-button secondary-button"
                      :type "submit"
                      "Room"))
           (:form :class "reset-form"
                  :method "post"
                  :action "/reset"
                  :hx-post "/reset"
                  :hx-target "#game"
                  :hx-swap "outerHTML"
             (:button :class "reset-button"
                      :type "submit"
                      "New")))))))

(defun render-game-fragment (game &key notice room-id player poll)
  (cl-who:with-html-output-to-string (stream)
    (:section :id "game"
              :class (css-classes "game-shell"
                                  (when (and (null (game-winner game))
                                             (null (game-active-board game)))
                                    "is-any-board")
                                  (when (game-over-p game) "is-over"))
              :hx-get (when poll (room-state-path room-id))
              :hx-trigger (when poll "every 2s")
              :hx-swap (when poll "outerHTML")
      (:header :class "topbar"
        (:div :class "title-block"
          (:p :class "eyebrow" "Ultimate Tic Tac Toe")
          (:h1 (cl-who:str (result-label game))))
        (:div :class "topbar-controls"
          (:div :class "status-pills"
            (when room-id
              (cl-who:htm
               (:span :class "status-pill"
                 (:span "Room")
                 (:strong (cl-who:str room-id)))
               (:span :class "status-pill"
                 (:span "You")
                 (:strong (cl-who:str (player-seat-label player))))))
            (:span :class "status-pill"
              (:span "Next")
              (:strong (cl-who:str (if (game-over-p game)
                                       "-"
                                       (player-label (game-next-player game))))))
            (:span :class "status-pill"
              (:span "Target")
              (:strong (cl-who:str (target-label game)))))
          (emit-actions stream room-id)))
      (emit-confetti stream game)
      (when notice
        (cl-who:htm
         (:p :class "notice"
             (cl-who:str notice))))
      (:div :class "play-layout"
        (:div :class "macro-board"
          (loop for board below 9
                do (emit-local-board stream game board
                                     :room-id room-id
                                     :player player)))))))

(defun render-page (game &key notice room-id player poll)
  (cl-who:with-html-output-to-string (stream nil :prologue t)
    (:html :lang "en"
      (:head
        (:meta :charset "utf-8")
        (:meta :name "viewport"
               :content "width=device-width, initial-scale=1")
        (:title "Ultimate Tic Tac Toe")
        (:link :rel "icon"
               :href "/icon.svg"
               :type "image/svg+xml")
        (:link :rel "stylesheet"
               :href "/style.css")
        (:script :src "/htmx.min.js"
                 :defer "defer"
                 " "))
      (:body
        (:main :class "app"
          (cl-who:str (render-game-fragment game
                                            :notice notice
                                            :room-id room-id
                                            :player player
                                            :poll poll)))))))

(hunchentoot:define-easy-handler (home :uri "/") ()
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (render-page (current-game)))

(hunchentoot:define-easy-handler (move :uri "/move"
                                       :default-request-type :post)
    (board cell)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (let ((game (current-game))
        (board-index (parse-index board))
        (cell-index (parse-index cell)))
    (if (and board-index cell-index)
        (multiple-value-bind (updated-game acceptedp)
            (play-move game board-index cell-index)
          (declare (ignore updated-game))
          (render-game-fragment
           game
           :notice (unless acceptedp
                     "That square is no longer available.")))
        (render-game-fragment game
                              :notice "That move was not understood."))))

(hunchentoot:define-easy-handler (reset :uri "/reset"
                                        :default-request-type :post)
    ()
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (render-game-fragment (replace-current-game)))

(hunchentoot:define-easy-handler (new-room :uri "/room/new"
                                           :default-request-type :post)
    ()
  (let ((room (create-room)))
    (claim-room-player room)
    (redirect-see-other (room-id-path (game-room-id room)))))

(hunchentoot:define-easy-handler (room-page :uri "/room") (id)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (let ((room (find-room id)))
    (if room
        (let ((player (claim-room-player room)))
          (with-room-locked (room)
            (render-page (game-room-game room)
                         :room-id (game-room-id room)
                         :player player
                         :poll t)))
        (render-page (current-game)
                     :notice "Room not found."))))

(hunchentoot:define-easy-handler (room-state :uri "/room/state") (id)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (let ((room (find-room id)))
    (if room
        (let ((player (claim-room-player room)))
          (with-room-locked (room)
            (render-game-fragment (game-room-game room)
                                  :room-id (game-room-id room)
                                  :player player
                                  :poll t)))
        (render-game-fragment (current-game)
                              :notice "Room not found."))))

(hunchentoot:define-easy-handler (room-move :uri "/room/move"
                                            :default-request-type :post)
    (id board cell)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (let ((room (find-room id)))
    (if room
        (let ((player (claim-room-player room))
              (board-index (parse-index board))
              (cell-index (parse-index cell)))
          (with-room-locked (room)
            (let ((game (game-room-game room)))
              (cond
                ((not (playable-player-p player))
                 (render-game-fragment game
                                       :room-id (game-room-id room)
                                       :player player
                                       :poll t
                                       :notice "This room is full."))
                ((not (eql player (game-next-player game)))
                 (render-game-fragment game
                                       :room-id (game-room-id room)
                                       :player player
                                       :poll t
                                       :notice (format nil "Waiting for ~A."
                                                       (player-label (game-next-player game)))))
                ((and board-index cell-index)
                 (multiple-value-bind (updated-game acceptedp)
                     (play-move game board-index cell-index)
                   (declare (ignore updated-game))
                   (render-game-fragment
                    game
                    :room-id (game-room-id room)
                    :player player
                    :poll t
                    :notice (unless acceptedp
                              "That square is no longer available."))))
                (t
                 (render-game-fragment game
                                       :room-id (game-room-id room)
                                       :player player
                                       :poll t
                                       :notice "That move was not understood."))))))
        (render-game-fragment (current-game)
                              :notice "Room not found."))))

(hunchentoot:define-easy-handler (room-reset :uri "/room/reset"
                                             :default-request-type :post)
    (id)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (let ((room (find-room id)))
    (if room
        (let ((player (claim-room-player room)))
          (with-room-locked (room)
            (if (playable-player-p player)
                (progn
                  (setf (game-room-game room) (make-game))
                  (render-game-fragment (game-room-game room)
                                        :room-id (game-room-id room)
                                        :player player
                                        :poll t))
                (render-game-fragment (game-room-game room)
                                      :room-id (game-room-id room)
                                      :player player
                                      :poll t
                                      :notice "This room is full."))))
        (render-game-fragment (current-game)
                              :notice "Room not found."))))

(hunchentoot:define-easy-handler (style :uri "/style.css") ()
  (handle-asset "static/style.css" "text/css; charset=utf-8"))

(hunchentoot:define-easy-handler (htmx :uri "/htmx.min.js") ()
  (handle-asset "static/htmx.min.js" "application/javascript; charset=utf-8"))

(hunchentoot:define-easy-handler (icon :uri "/icon.svg") ()
  (handle-asset "static/icon.svg" "image/svg+xml"))

(hunchentoot:define-easy-handler (x-mark :uri "/x.svg") ()
  (handle-asset "static/x.svg" "image/svg+xml"))

(hunchentoot:define-easy-handler (o-mark :uri "/o.svg") ()
  (handle-asset "static/o.svg" "image/svg+xml"))

(defun start (&key (port 4242) (address "127.0.0.1"))
  (stop)
  (seed-random-state)
  (configure-session-secret)
  (setf *acceptor*
        (hunchentoot:start
         (make-instance 'hunchentoot:easy-acceptor
                        :address address
                        :port port)))
  *acceptor*)

(defun stop ()
  (when *acceptor*
    (hunchentoot:stop *acceptor*)
    (setf *acceptor* nil))
  nil)

(defun server-port ()
  (when *acceptor*
    (hunchentoot:acceptor-port *acceptor*)))
