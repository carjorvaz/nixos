# Agent Notes

- `AGENTS.md` is the canonical shared guidance for coding agents in this repo. Keep `CLAUDE.md` as a tiny import stub pointing at this file with `@AGENTS.md`.
- Keep this file concise and stable. Add only repo-specific guidance that should hold across sessions; avoid status notes, deadlines, or one-off task history.

## Remote Access

- This repo manages remote NixOS hosts and commonly uses SSH-based workflows.
- In this environment, Tailscale and MagicDNS are not available from the default sandboxed shell.
- If an SSH command like `ssh pius` fails with name resolution or connectivity issues from the sandbox, retry it with escalated permissions.
- Verified on 2026-04-11: `ssh -o BatchMode=yes -o ConnectTimeout=5 pius true` succeeds when run with escalation.
- Treat remote rebuilds, deploys, and host-changing commands as confirmation-required unless the user explicitly asks for them.

## Flake Workflow

- This repo is evaluated through flakes, so imported modules and other newly created files must be git-tracked before Nix will reliably see them from the flake snapshot.
- Prefer `nix eval` and `nix build` to validate changes before running mutating rebuild or deploy commands.
- Treat local `darwin-rebuild switch` the same way as remote deploys: confirmation-required unless the user explicitly asks for it.

## Nix Patterns

- Before hand-rolling a systemd service, check whether nixpkgs already provides a NixOS module (`services.*`); prefer upstream modules when they exist.
- For `services.zfsBackup.source` on roaming hosts where the target should retain real snapshot history, prefer `snapshotMode = "existing"` with `createBookmark = true` over keeping `syncoid_*` snapshots; filtering out `autosnap_*_frequently` is usually a good fit.
- `pkgs.unstable.*` is available on stable hosts via the overlay in `profiles/nixos/base.nix`.
- `trajanus` uses `nixpkgs-unstable` as its base in `flake.nix`, so `pkgs.*` there is already unstable; no `pkgs.unstable` prefix needed.
- Shared modules are used across both stable and unstable nixpkgs pins; when option paths are renamed between channels, prefer a small version guard over an unconditional rewrite.
- On impermanent hosts using libvirt's encrypted secrets, persist `/var/lib/systemd/credential.secret`; if `virt-secret-init-encryption.service` assumes `/usr/bin/sh`, override it to use `${pkgs.runtimeShell}`.
- Paths in `environment.persistence."/persist".directories` are relative to root, not to `/persist`. Example: `[ "/var/lib/foo" ]` bind-mounts `/persist/var/lib/foo` to `/var/lib/foo`.
- Avoid `inputs.*.inputs.nixpkgs.follows` for fast-moving forks; they often depend on newer nixpkgs features than the stable channel pin.

## Landing And Reflection

- When the conversation seems to be winding down, do a landing-and-reflection pass before the final answer.
- Finish adjacent cleanup, verification, or tidy-up that clearly helps the work feel properly landed.
- If there is worthwhile nearby follow-on work, continue into it when it remains closely related to the task; if it would broaden scope or involve non-obvious tradeoffs, surface that explicitly.
- Before closing, note meaningful remaining opportunities so the user can choose whether to keep going.
- Update `AGENTS.md` only when the session revealed a stable, reusable, repo-specific lesson likely to improve future agent behavior.
- Prefer meaningful adjustment over note accumulation: do not add guidance that is obvious from the code, specific only to one session, or unlikely to matter again.
