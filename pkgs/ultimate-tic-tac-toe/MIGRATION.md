# Ultimate Tic Tac Toe Source Migration

This package currently builds from the in-repo `source/` tree. Keep that as the
deployed source of truth until a replacement source preserves the live service
contract below.

## Current Service Contract

- `ultimate-tic-tac-toe.carjorvaz.com` serves the in-repo Common Lisp app.
- `/health` returns `ok` for service checks.
- `/room/new`, `/room/join`, and `/room` provide shareable room links.
- Room state is stored through SQLite via `UTTT_ROOM_DB`.
- Runtime persistence is backed by the NixOS service state directory.
- Room pages support two-player seat assignment and live room updates.
- Old `uttt.vaz.one` URLs redirect to the current domain.

## External Source Audit

The external `carjorvaz/cl-ultimate-tic-tac-toe` app appears to be a stronger
standalone application in several ways: it has clearer architecture documents,
Clack/Lack/Ningle plumbing, Woo support, browser smoke tooling, and `/version`
in addition to `/health`.

It is not currently feature-compatible with the deployed service. The audited
version stores game state in the Lack session, does not read `UTTT_ROOM_DB`, and
does not expose the deployed room-sharing and live multi-client room workflow.

## Decision

Do not switch `default.nix` from `src = ./source` to the external repository
until the external app either implements the deployed multiplayer room contract
or there is an explicit product decision to replace that contract.

## Gate Checklist

- Persistent shareable rooms exist, or there is a deliberate migration away from
  them.
- Existing room links have a compatibility or expiry story.
- Live two-player updates work across separate browser sessions.
- Storage configuration replaces or intentionally retires `UTTT_ROOM_DB`.
- The NixOS service state directory remains meaningful, or is removed with the
  storage migration.
- `/health` continues to return a plain `ok` response.
- Domain redirects and security headers are preserved.
- Nix package build and tests pass.
- A remote `hadrianus` build passes before deployment.
- Manual two-browser smoke covers room create, join, move, reset, and reconnect.
