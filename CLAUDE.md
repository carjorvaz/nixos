# NixOS Config — Claude Notes

## Before hand-rolling a systemd service

Check if nixpkgs already has a NixOS module (`services.*`). Search nixpkgs or use `nix search` before writing custom systemd units — upstream modules include hardening, user management, and firewall integration for free.

## Package channels

- `pkgs.unstable.*` is available on stable hosts via the overlay in `profiles/nixos/base.nix`.
- trajanus uses `nixpkgs-unstable` as its base (`nixpkgs-unstable.lib.nixosSystem` in `flake.nix`), so `pkgs.*` is already unstable there — no `pkgs.unstable` prefix needed.

## Impermanence

Paths in `environment.persistence."/persist".directories` are relative to root, not to `/persist`. Example: `[ "/var/lib/foo" ]` bind-mounts `/persist/var/lib/foo` to `/var/lib/foo`. Don't add paths that are already under `/persist`.

## Flake inputs

Don't use `inputs.*.inputs.nixpkgs.follows` for fast-moving forks — they often depend on newer nixpkgs features that break when pinned to our stable channel.
