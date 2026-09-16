# Repository Docs

This directory documents the repository's architecture, tooling, validation, and public/private boundaries.

Start here:

- [Architecture](ARCHITECTURE.md) — flake layout, host/profile/module boundaries, and where new work belongs.
- [Validation](VALIDATION.md) — safe local checks and when to use stronger Nix evaluations/builds.
- [Tooling](TOOLING.md) — high-leverage tooling defaults for the dev shell, `just`, Jujutsu-on-Git, and review surfaces.
- [Public boundary](PUBLIC_BOUNDARY.md) — what is safe to commit, evaluate, log, or run in a public infrastructure repository.
- [Plans](PLANS.md) — when to create checked-in execution plans and when to keep notes private.
