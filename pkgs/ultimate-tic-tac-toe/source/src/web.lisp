;;;; SPDX-License-Identifier: AGPL-3.0-or-later

(in-package #:ultimate-tic-tac-toe.web)

(defparameter *acceptor* nil)
(defparameter *rooms* (make-hash-table :test #'equal))
(defparameter *rooms-lock* (bordeaux-threads:make-lock "ultimate-tic-tac-toe rooms"))
(defparameter *room-database* nil)
(defparameter *room-database-path* nil)
(defparameter +room-code-alphabet+ "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
(defparameter +room-code-length+ 6)
(defparameter +room-ttl-seconds+ (* 18 60 60))
(defparameter +room-poll-trigger+ "every 10s")
(defparameter +room-event-timeout-seconds+ 25)
(defparameter +visitor-cookie-name+ "uttt-visitor")
(defparameter +visitor-cookie-max-age+ (* 365 24 60 60))

(defstruct (game-room (:constructor make-game-room))
  id
  game
  x-player
  o-player
  (version 0)
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

(defun parse-nonnegative-integer (value &optional (default 0))
  (handler-case
      (let ((integer (parse-integer value :junk-allowed nil)))
        (if (minusp integer)
            default
            integer))
    (error () default)))

(defun normalized-version (value)
  (cond
    ((integerp value) (max value 0))
    ((stringp value) (parse-nonnegative-integer value))
    (t 0)))

(defun room-id-path (game-room-id)
  (format nil "/room?id=~A" game-room-id))

(defun room-state-path (game-room-id)
  (format nil "/room/state?id=~A" game-room-id))

(defun room-events-path (game-room-id version)
  (format nil "/room/events?id=~A&version=~D" game-room-id version))

(defun redirect-see-other (path)
  (setf (hunchentoot:header-out :location) path
        (hunchentoot:return-code*) hunchentoot:+http-see-other+)
  (hunchentoot:abort-request-handler))

(defun mark-noindex-response ()
  (setf (hunchentoot:header-out :x-robots-tag) "noindex, nofollow"))

(defun room-code-characters (value)
  (when value
    (loop for character across value
          for upper = (char-upcase character)
          when (alphanumericp upper)
            collect upper)))

(defun normalize-game-room-id (game-room-id)
  (let ((characters (room-code-characters game-room-id)))
    (when (and (= (length characters) +room-code-length+)
               (loop for character in characters
                     always (find character +room-code-alphabet+
                                  :test #'char=)))
      (coerce characters 'string))))

(defun random-token (&optional (length +room-code-length+))
  (let ((alphabet-length (length +room-code-alphabet+)))
    (coerce
     (loop repeat length
           collect (aref +room-code-alphabet+
                         (random alphabet-length)))
     'string)))

(defun token-string-p (value &optional (length nil length-provided-p))
  (and (stringp value)
       (or (not length-provided-p)
           (= (length value) length))
       (loop for character across value
             always (find character +room-code-alphabet+ :test #'char=))))

(defun visitor-id ()
  (or (let ((cookie-value (hunchentoot:cookie-in +visitor-cookie-name+)))
        (when (token-string-p cookie-value 18)
          cookie-value))
      (let ((new-id (random-token 18)))
        (hunchentoot:set-cookie +visitor-cookie-name+
                                :value new-id
                                :path "/"
                                :max-age +visitor-cookie-max-age+
                                :http-only t)
        new-id)))

(defun fresh-game-room-id ()
  (loop repeat 128
        for game-room-id = (random-token)
        unless (gethash game-room-id *rooms*)
          return game-room-id
        finally (error "Could not make a room id.")))

(defun room-database-path ()
  (or (uiop:getenv "UTTT_ROOM_DB")
      (let ((state-directory (uiop:getenv "STATE_DIRECTORY")))
        (when (and state-directory (plusp (length state-directory)))
          (namestring (merge-pathnames "rooms.sqlite3"
                                       (uiop:ensure-directory-pathname state-directory)))))
      (namestring (merge-pathnames "rooms.sqlite3"
                                   (user-homedir-pathname)))))

(defun print-readable-to-string (value)
  (with-standard-io-syntax
    (write-to-string value :readably t :pretty nil)))

(defun read-readable-from-string (value)
  (with-standard-io-syntax
    (let ((*read-eval* nil))
      (read-from-string value))))

(defun encode-game (game)
  (print-readable-to-string (game-snapshot game)))

(defun decode-game (serialized-game)
  (game-from-snapshot (read-readable-from-string serialized-game)))

(defun sqlite-row-value (row index)
  (etypecase row
    (list (nth index row))
    (vector (aref row index))))

(defun room-schema-column-p (database column-name)
  (loop for row in (sqlite:execute-to-list database "pragma table_info(rooms)")
        for row-column-name = (sqlite-row-value row 1)
        thereis (and row-column-name
                     (string-equal (string row-column-name) column-name))))

(defun ensure-room-schema (database)
  (sqlite:execute-non-query
   database
   "create table if not exists rooms (
      id text primary key,
      game text not null,
      x_player text,
      o_player text,
      version integer not null default 0,
      created_at integer not null,
      updated_at integer not null
    )")
  (unless (room-schema-column-p database "version")
    (sqlite:execute-non-query
     database
     "alter table rooms add column version integer not null default 0")))

(defun database-row-room (row)
  (destructuring-bind (id serialized-game x-player o-player version created-at updated-at) row
    (make-game-room :id id
                    :game (decode-game serialized-game)
                    :x-player x-player
                    :o-player o-player
                    :version (normalized-version version)
                    :created-at created-at
                    :updated-at updated-at)))

(defun load-rooms-from-database ()
  (setf *rooms* (make-hash-table :test #'equal))
  (when *room-database*
    (dolist (row (sqlite:execute-to-list
                  *room-database*
                  "select id, game, x_player, o_player, version, created_at, updated_at from rooms"))
      (let ((room (database-row-room row)))
        (setf (gethash (game-room-id room) *rooms*) room)))))

(defun persist-room-unlocked (room)
  (when *room-database*
    (sqlite:execute-non-query
     *room-database*
     "insert into rooms (id, game, x_player, o_player, version, created_at, updated_at)
      values (?, ?, ?, ?, ?, ?, ?)
      on conflict(id) do update set
        game = excluded.game,
        x_player = excluded.x_player,
        o_player = excluded.o_player,
        version = excluded.version,
        created_at = excluded.created_at,
        updated_at = excluded.updated_at"
     (game-room-id room)
     (encode-game (game-room-game room))
     (game-room-x-player room)
     (game-room-o-player room)
     (game-room-version room)
     (game-room-created-at room)
     (game-room-updated-at room))))

(defun delete-room-unlocked (game-room-id)
  (when *room-database*
    (sqlite:execute-non-query *room-database*
                              "delete from rooms where id = ?"
                              game-room-id)))

(defun initialize-room-store (&optional (path (room-database-path)))
  (bordeaux-threads:with-lock-held (*rooms-lock*)
    (when *room-database*
      (sqlite:disconnect *room-database*))
    (setf *room-database-path* path
          *room-database* (sqlite:connect path :busy-timeout 5000))
    (ensure-room-schema *room-database*)
    (load-rooms-from-database)
    (prune-rooms)))

(defun close-room-store ()
  (bordeaux-threads:with-lock-held (*rooms-lock*)
    (when *room-database*
      (sqlite:disconnect *room-database*))
    (setf *room-database* nil
          *room-database-path* nil
          *rooms* (make-hash-table :test #'equal))))

(defun prune-rooms ()
  (let ((oldest (- (get-universal-time) +room-ttl-seconds+))
        expired-room-ids)
    (maphash (lambda (game-room-id room)
               (when (< (game-room-updated-at room) oldest)
                 (push game-room-id expired-room-ids)))
             *rooms*)
    (dolist (game-room-id expired-room-ids)
      (remhash game-room-id *rooms*)
      (delete-room-unlocked game-room-id))))

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
      (persist-room-unlocked room)
      room)))

(defun touch-room-unlocked (room)
  (setf (game-room-updated-at room) (get-universal-time))
  room)

(defun note-room-change-unlocked (room)
  (setf (game-room-version room) (1+ (normalized-version
                                      (game-room-version room))))
  (touch-room-unlocked room))

(defun find-room (game-room-id)
  (let ((normalized-id (normalize-game-room-id game-room-id)))
    (when normalized-id
      (bordeaux-threads:with-lock-held (*rooms-lock*)
        (gethash normalized-id *rooms*)))))

(defun claim-room-player (room)
  (let ((visitor-id (visitor-id)))
    (bordeaux-threads:with-lock-held (*rooms-lock*)
      (cond
        ((equal visitor-id (game-room-x-player room))
         :x)
        ((null (game-room-x-player room))
         (setf (game-room-x-player room) visitor-id)
         (note-room-change-unlocked room)
         (persist-room-unlocked room)
         :x)
        ((equal visitor-id (game-room-o-player room))
         :o)
        ((null (game-room-o-player room))
         (setf (game-room-o-player room) visitor-id)
         (note-room-change-unlocked room)
         (persist-room-unlocked room)
         :o)
        (t :spectator)))))

(defun current-room-version (game-room-id)
  (let ((normalized-id (normalize-game-room-id game-room-id)))
    (if normalized-id
        (bordeaux-threads:with-lock-held (*rooms-lock*)
          (let ((room (gethash normalized-id *rooms*)))
            (if room
                (values (normalized-version (game-room-version room)) t)
                (values nil nil))))
        (values nil nil))))

(defun wait-for-room-event (game-room-id known-version)
  (let ((deadline (+ (get-universal-time) +room-event-timeout-seconds+))
        (known-version (or known-version 0))
        (last-seen-version known-version))
    (loop
      (multiple-value-bind (current-version foundp)
          (current-room-version game-room-id)
        (unless foundp
          (return (values :gone nil)))
        (setf last-seen-version current-version)
        (when (> current-version known-version)
          (return (values :room current-version)))
        (when (>= (get-universal-time) deadline)
          (return (values :ping last-seen-version))))
      (sleep 0.25))))

(defun event-stream-response (event data &key id)
  (with-output-to-string (stream)
    (format stream "retry: 1000~%")
    (when id
      (format stream "id: ~A~%" id))
    (format stream "event: ~A~%" event)
    (format stream "data: ~A~%~%" data)))

(defun playable-player-p (player)
  (or (eql player :x)
      (eql player :o)))

(defun room-ready-p (room)
  (and room
       (game-room-x-player room)
       (game-room-o-player room)))

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

(defun room-seat-state-label (room seat player)
  (let ((claimedp (ecase seat
                    (:x (game-room-x-player room))
                    (:o (game-room-o-player room)))))
    (cond
      ((not claimedp) "Open")
      ((eql seat player) "You")
      (t "Ready"))))

(defun room-headline-label (game room player)
  (cond
    ((game-over-p game) (result-label game))
    ((not (room-ready-p room)) "Waiting for O")
    ((not (playable-player-p player)) "Watching live")
    ((eql player (game-next-player game)) "Your move")
    (t (format nil "Waiting for ~A"
               (player-label (game-next-player game))))))

(defun room-message-label (game room player)
  (cond
    ((and (game-over-p game)
          (last-move-message game)))
    ((game-over-p game) "Start a new game when both players are ready.")
    ((not (room-ready-p room)) "Share the link. The board opens when O joins.")
    ((last-move-message game))
    ((not (playable-player-p player))
     (format nil "Watching ~A choose ~A."
             (player-label (game-next-player game))
             (target-instruction-label game)))
    ((eql player (game-next-player game))
     (format nil "Choose ~A." (target-instruction-label game)))
    (t (format nil "Waiting for ~A to choose ~A."
               (player-label (game-next-player game))
               (target-instruction-label game)))))

(defmacro with-room-locked ((room) &body body)
  `(bordeaux-threads:with-lock-held (*rooms-lock*)
     (touch-room-unlocked ,room)
     (multiple-value-prog1 (progn ,@body)
       (persist-room-unlocked ,room))))

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
     (board-position-label (game-active-board game)))
    (t "Any board")))

(defun target-instruction-label (game)
  (cond
    ((game-winner game) "the finished game")
    ((game-active-board game)
     (format nil "the ~A board"
             (board-position-label (game-active-board game))))
    (t "any open board")))

(defun last-move-target-label (last-move)
  (let ((target-board (getf last-move :target-board)))
    (when target-board
      (format nil "the ~A board" (board-position-label target-board)))))

(defun last-move-message (game)
  (let ((last-move (game-last-move game)))
    (when last-move
      (let ((last-player (getf last-move :player)))
        (cond
          ((eql (game-winner game) :draw)
           (format nil "~A made the final move. The game is drawn."
                   (player-label last-player)))
          ((player-label-p (game-winner game))
           (format nil "~A made the final move and won."
                   (player-label last-player)))
          ((last-move-target-label last-move)
           (format nil "~A sent ~A to ~A."
                   (player-label last-player)
                   (player-label (game-next-player game))
                   (last-move-target-label last-move)))
          (t
           (format nil "~A opened any board for ~A."
                   (player-label last-player)
                   (player-label (game-next-player game)))))))))

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

(defun last-move-board-p (game board)
  (let ((last-move (game-last-move game)))
    (and last-move
         (= board (getf last-move :board)))))

(defun last-move-cell-p (game board cell)
  (let ((last-move (game-last-move game)))
    (and last-move
         (= board (getf last-move :board))
         (= cell (getf last-move :cell)))))

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

(defun emit-cell (stream game board cell &key room-id player (play-enabled-p t))
  (let ((mark (mark-at game board cell))
        (legalp (and (legal-move-p game board cell)
                     play-enabled-p
                     (player-turn-p game player))))
    (cl-who:with-html-output (stream)
      (:div :class (css-classes "micro-cell"
                                (when mark "is-filled")
                                (when (last-move-cell-p game board cell)
                                  "is-last-move")
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

(defun emit-local-board (stream game board &key room-id player (play-enabled-p t))
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
                                      "is-global-win-board")
                                    (when (last-move-board-p game board)
                                      "has-last-move"))
                :aria-label (format nil "Board ~D, ~A"
                                    (1+ board)
                                    (outcome-label outcome))
        (:div :class "micro-grid"
          (loop for cell below 9
                do (emit-cell stream game board cell
                              :room-id room-id
                              :player player
                              :play-enabled-p play-enabled-p))
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

(defun emit-join-form (stream &key code error)
  (cl-who:with-html-output (stream)
    (:form :class (css-classes "join-form"
                               (when error "has-error"))
           :method "get"
           :action "/room/join"
      (:div :class "join-fields"
        (:label :class "sr-only"
                :for "room-code"
                "Room code")
        (:input :class "join-input"
                :id "room-code"
                :name "code"
                :type "text"
                :inputmode "text"
                :autocomplete "off"
                :autocapitalize "characters"
                :spellcheck "false"
                :maxlength 14
                :placeholder "Room code"
                :value (or code ""))
        (:button :class "reset-button join-button"
                 :type "submit"
                 "Join"))
      (when error
        (cl-who:htm
         (:p :class "join-error"
             (cl-who:str error)))))))

(defun emit-new-room-form (stream &key (label "New room") secondary)
  (cl-who:with-html-output (stream)
    (:form :class "reset-form"
           :method "post"
           :action "/room/new"
      (:button :class (css-classes "reset-button"
                                   (when secondary "secondary-button"))
               :type "submit"
               (cl-who:str label)))))

(defun emit-actions (stream room-id &key join-code join-error)
  (cl-who:with-html-output (stream)
    (:div :class "action-forms"
      (if room-id
          (cl-who:htm
           (:button :class "reset-button secondary-button invite-button"
                    :type "button"
                    :aria-label "Invite a player to this room"
                    :data-room-path (room-id-path room-id)
                    :data-room-share "true"
                    "Invite")
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
           (emit-join-form stream
                           :code join-code
                           :error join-error)
           (emit-new-room-form stream :secondary t)
           (:form :class "reset-form"
                  :method "post"
                  :action "/reset"
                  :hx-post "/reset"
                  :hx-target "#game"
                  :hx-swap "outerHTML"
             (:button :class "reset-button"
                      :type "submit"
                      "Reset")))))))

(defun render-game-fragment (game &key notice room-id room player poll
                                    join-code join-error)
  (cl-who:with-html-output-to-string (stream)
    (:section :id "game"
              :class (css-classes "game-shell"
                                  (when room-id "has-room")
                                  (when (and (null (game-winner game))
                                             (null (game-active-board game)))
                                    "is-any-board")
                                  (when (game-over-p game) "is-over"))
              :hx-get (when poll (room-state-path room-id))
              :hx-trigger (when poll +room-poll-trigger+)
              :hx-swap (when poll "outerHTML")
              :data-room-id room-id
              :data-room-version (when room
                                   (game-room-version room))
              :data-room-events (when room
                                  (room-events-path room-id
                                                    (game-room-version room)))
      (:header :class "topbar"
        (:div :class "title-block"
          (:p :class "eyebrow" "Ultimate Tic Tac Toe")
          (:h1 (cl-who:str (if room-id
                                (room-headline-label game room player)
                                (result-label game))))
          (when room-id
            (cl-who:htm
             (:p :class "room-message"
                 :aria-live "polite"
                 (cl-who:str (room-message-label game room player))))))
        (:div :class "topbar-controls"
          (:div :class "status-pills"
            (when room-id
              (cl-who:htm
               (:span :class "status-pill room-pill"
                 (:span "Room")
                 (:strong (cl-who:str room-id))
                 (:span :class "live-state"
                        :data-live-state "syncing"
                        :aria-label "Live updates connecting"
                   (:span :class "live-dot"
                          :aria-hidden "true")
                   (:span :class "live-label" "Sync")))
               (:span :class (css-classes "status-pill"
                                          "seat-pill"
                                          "seat-x"
                                          (when (eql player :x) "is-you"))
                 (:span "X")
                 (:strong (cl-who:str (room-seat-state-label room :x player))))
               (:span :class (css-classes "status-pill"
                                          "seat-pill"
                                          "seat-o"
                                          (when (eql player :o) "is-you")
                                          (unless (game-room-o-player room) "is-open"))
                 (:span "O")
                 (:strong (cl-who:str (room-seat-state-label room :o player))))))
            (unless room-id
              (cl-who:htm
               (:span :class "status-pill"
                 (:span "Next")
                 (:strong (cl-who:str (if (game-over-p game)
                                          "-"
                                          (player-label (game-next-player game))))))))
              (:span :class "status-pill target-pill"
                (:span "Target")
                (:strong (cl-who:str (target-label game)))))
          (emit-actions stream room-id
                        :join-code join-code
                        :join-error join-error)))
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
                                     :player player
                                     :play-enabled-p (if room-id
                                                         (room-ready-p room)
                                                         t))))))))

(defun render-missing-room-fragment (&key room-id join-code join-error)
  (cl-who:with-html-output-to-string (stream)
    (:section :id "game"
              :class "game-shell is-missing-room"
      (:header :class "topbar"
        (:div :class "title-block"
          (:p :class "eyebrow" "Ultimate Tic Tac Toe")
          (:h1 "Room not found")
          (:p :class "room-message"
              "Try another code or start a new room."))
        (:div :class "topbar-controls"
          (:div :class "status-pills"
            (when room-id
              (cl-who:htm
               (:span :class "status-pill room-pill"
                 (:span "Code")
                 (:strong (cl-who:str room-id))))))))
      (:div :class "missing-room-panel"
        (:div :class "missing-room-code"
              (cl-who:str (or room-id "------")))
        (emit-join-form stream
                        :code (or join-code room-id)
                        :error join-error)
        (emit-new-room-form stream)))))

(defun render-app-page (content &key noindex)
  (when noindex
    (mark-noindex-response))
  (cl-who:with-html-output-to-string (stream nil :prologue t)
    (:html :lang "en"
      (:head
        (:meta :charset "utf-8")
        (:meta :name "viewport"
               :content "width=device-width, initial-scale=1")
        (when noindex
          (cl-who:htm
           (:meta :name "robots"
                  :content "noindex, nofollow")))
        (:title "Ultimate Tic Tac Toe")
        (:link :rel "icon"
               :href "/icon.svg"
               :type "image/svg+xml")
        (:link :rel "stylesheet"
               :href "/style.css")
        (:script :src "/htmx.min.js"
                 :defer "defer"
                 " ")
        (:script :src "/room-events.js"
                 :defer "defer"
                 " "))
      (:body
        (:main :class "app"
          (cl-who:str content))))))

(defun render-page (game &key notice room-id room player poll
                          join-code join-error noindex)
  (render-app-page (render-game-fragment game
                                         :notice notice
                                         :room-id room-id
                                         :room room
                                         :player player
                                         :poll poll
                                         :join-code join-code
                                         :join-error join-error)
                   :noindex noindex))

(defun render-missing-room-page (&key room-id join-code join-error)
  (render-app-page (render-missing-room-fragment
                    :room-id room-id
                    :join-code join-code
                    :join-error join-error)
                   :noindex t))

(hunchentoot:define-easy-handler (home :uri "/") ()
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (render-page (current-game)))

(hunchentoot:define-easy-handler (robots :uri "/robots.txt") ()
  (setf (hunchentoot:content-type*) "text/plain; charset=utf-8")
  (format nil "User-agent: *~%Disallow: /room?~%Disallow: /room/~%"))

(hunchentoot:define-easy-handler (health :uri "/health") ()
  (setf (hunchentoot:content-type*) "text/plain; charset=utf-8"
        (hunchentoot:header-out :cache-control) "no-store")
  (format nil "ok~%"))

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
  (mark-noindex-response)
  (let ((room (create-room)))
    (claim-room-player room)
    (redirect-see-other (room-id-path (game-room-id room)))))

(hunchentoot:define-easy-handler (join-room :uri "/room/join") (code)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (mark-noindex-response)
  (let ((room-id (normalize-game-room-id code)))
    (if room-id
        (redirect-see-other (room-id-path room-id))
        (render-page (current-game)
                     :join-code code
                     :join-error "Enter a valid room code."
                     :noindex t))))

(hunchentoot:define-easy-handler (room-page :uri "/room") (id)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (mark-noindex-response)
  (let* ((room-id (normalize-game-room-id id))
         (room (and room-id (find-room room-id))))
    (if room
        (let ((player (claim-room-player room)))
          (with-room-locked (room)
            (render-page (game-room-game room)
                         :room-id (game-room-id room)
                         :room room
                         :player player
                         :poll t
                         :noindex t)))
        (render-missing-room-page
         :room-id room-id
         :join-code (or room-id id)
         :join-error "No room with that code."))))

(hunchentoot:define-easy-handler (room-state :uri "/room/state") (id)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (mark-noindex-response)
  (let* ((room-id (normalize-game-room-id id))
         (room (and room-id (find-room room-id))))
    (if room
        (let ((player (claim-room-player room)))
          (with-room-locked (room)
            (render-game-fragment (game-room-game room)
                                  :room-id (game-room-id room)
                                  :room room
                                  :player player
                                  :poll t)))
        (render-missing-room-fragment
         :room-id room-id
         :join-code (or room-id id)
         :join-error "No room with that code."))))

(hunchentoot:define-easy-handler (room-move :uri "/room/move"
                                            :default-request-type :post)
    (id board cell)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (mark-noindex-response)
  (let* ((room-id (normalize-game-room-id id))
         (room (and room-id (find-room room-id))))
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
                                       :room room
                                       :player player
                                       :poll t
                                       :notice "This room is full."))
                ((not (room-ready-p room))
                 (render-game-fragment game
                                       :room-id (game-room-id room)
                                       :room room
                                       :player player
                                       :poll t
                                       :notice "Waiting for O to join."))
                ((not (eql player (game-next-player game)))
                 (render-game-fragment game
                                       :room-id (game-room-id room)
                                       :room room
                                       :player player
                                       :poll t
                                       :notice (format nil "Waiting for ~A."
                                                       (player-label (game-next-player game)))))
                ((and board-index cell-index)
                 (multiple-value-bind (updated-game acceptedp)
                     (play-move game board-index cell-index)
                   (declare (ignore updated-game))
                   (when acceptedp
                     (note-room-change-unlocked room))
                   (render-game-fragment
                    game
                    :room-id (game-room-id room)
                    :room room
                    :player player
                    :poll t
                    :notice (unless acceptedp
                              "That square is no longer available."))))
                (t
                 (render-game-fragment game
                                       :room-id (game-room-id room)
                                       :room room
                                       :player player
                                       :poll t
                                       :notice "That move was not understood."))))))
        (render-missing-room-fragment
         :room-id room-id
         :join-code (or room-id id)
         :join-error "No room with that code."))))

(hunchentoot:define-easy-handler (room-reset :uri "/room/reset"
                                             :default-request-type :post)
    (id)
  (setf (hunchentoot:content-type*) "text/html; charset=utf-8")
  (mark-noindex-response)
  (let* ((room-id (normalize-game-room-id id))
         (room (and room-id (find-room room-id))))
    (if room
        (let ((player (claim-room-player room)))
          (with-room-locked (room)
            (if (playable-player-p player)
                (progn
                  (setf (game-room-game room) (make-game))
                  (note-room-change-unlocked room)
                  (render-game-fragment (game-room-game room)
                                        :room-id (game-room-id room)
                                        :room room
                                        :player player
                                        :poll t))
                (render-game-fragment (game-room-game room)
                                      :room-id (game-room-id room)
                                      :room room
                                      :player player
                                      :poll t
                                      :notice "This room is full."))))
        (render-missing-room-fragment
         :room-id room-id
         :join-code (or room-id id)
         :join-error "No room with that code."))))

(hunchentoot:define-easy-handler (room-events :uri "/room/events") (id version)
  (setf (hunchentoot:content-type*) "text/event-stream; charset=utf-8"
        (hunchentoot:header-out :cache-control) "no-cache")
  (mark-noindex-response)
  (multiple-value-bind (event event-version)
      (wait-for-room-event id (parse-nonnegative-integer version))
    (case event
      (:room (event-stream-response "room" event-version :id event-version))
      (:gone (event-stream-response "gone" "gone"))
      (otherwise (event-stream-response "ping" (or event-version 0)
                                        :id (or event-version 0))))))

(hunchentoot:define-easy-handler (style :uri "/style.css") ()
  (handle-asset "static/style.css" "text/css; charset=utf-8"))

(hunchentoot:define-easy-handler (htmx :uri "/htmx.min.js") ()
  (handle-asset "static/htmx.min.js" "application/javascript; charset=utf-8"))

(hunchentoot:define-easy-handler (room-events-script :uri "/room-events.js") ()
  (handle-asset "static/room-events.js" "application/javascript; charset=utf-8"))

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
  (initialize-room-store)
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
  (close-room-store)
  nil)

(defun server-port ()
  (when *acceptor*
    (hunchentoot:acceptor-port *acceptor*)))
