# Repository Docs

This directory is the repo-local source of truth for durable guidance that is too detailed for `AGENTS.md`.

Start here:

- [Architecture](ARCHITECTURE.md) — flake layout, host/profile/module boundaries, and where new work belongs.
- [Validation](VALIDATION.md) — safe local checks and when to use stronger Nix evaluations/builds.
- [Tooling](TOOLING.md) — sharp-tool defaults for the dev shell, `just`, Jujutsu-on-Git, and review surfaces.
- [Public boundary](PUBLIC_BOUNDARY.md) — what is safe to commit, evaluate, log, or run in a public infrastructure repository.
- [Plans](PLANS.md) — when to create checked-in execution plans and when to keep notes private.

Keep `AGENTS.md` short and map-like. Put stable rules in these focused docs, and promote rules to scripts or flake checks when repeated mistakes are easy to detect mechanically.
