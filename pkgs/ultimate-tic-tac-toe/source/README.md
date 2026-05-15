# Ultimate Tic Tac Toe

Server-rendered Ultimate Tic Tac Toe in Common Lisp, using Hunchentoot,
CL-WHO, and HTMX for small partial updates. Friend rooms use a small
server-sent event stream for live updates, with HTMX polling as a fallback.

HTMX is vendored at `static/htmx.min.js`; its 0BSD license is included at
`static/htmx.LICENSE`.

## Run

```sh
direnv allow
sbcl --script scripts/run.lisp
```

or without enabling direnv:

```sh
nix develop -c sbcl --script scripts/run.lisp
```

The app listens on `http://127.0.0.1:4242/` by default. Set `PORT` to change
the port. Set `SESSION_SECRET` for a stable Hunchentoot session secret in a
deployed service. Room state is stored in `rooms.sqlite3` under
`STATE_DIRECTORY` or `HOME`; set `UTTT_ROOM_DB` to override the database path.

## Rooms

Use the `Room` button to create a shareable friend room. Rooms are persisted in
SQLite and pruned after a period of inactivity. A room link seats the first
visitor as X, the second as O, and later visitors as spectators.

## Test

```sh
nix develop -c sbcl --script scripts/test.lisp
```

or:

```sh
nix flake check
```

## Notes

The Common Lisp project layout and library usage were checked against the
local corpus available at `ssh root@pius:/persist/lisp-corpus`.

## License

AGPL-3.0-or-later. See `LICENSE`. Vendored HTMX is 0BSD; see
`static/htmx.LICENSE`.
