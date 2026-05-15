# Ultimate Tic Tac Toe

Server-rendered Ultimate Tic Tac Toe in Common Lisp, using Hunchentoot,
CL-WHO, and HTMX for small partial updates.

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
deployed service.

## Rooms

Use the `Room` button to create a shareable friend room. Rooms are in-memory
and ephemeral: they are suitable for casual games, but they are cleared when
the service restarts.

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
