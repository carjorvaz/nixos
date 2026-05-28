# Architecture

This repository is a public Nix flake for personal NixOS, nix-darwin, packages, modules, and encrypted secrets.

## Top-level layout

- `flake.nix` / `flake.lock` — flake inputs, overlays, package discovery, host systems, and checks.
- `hosts/` — concrete machine configurations. Host files should compose modules and profiles rather than accumulating reusable logic.
- `profiles/nixos/` — reusable NixOS profiles and service composition for this infrastructure.
- `profiles/darwin/` — nix-darwin configuration used by the Mac host.
- `profiles/home-manager/` — Home Manager configuration shared by host profiles.
- `modules/nixos/` — reusable NixOS modules. Keep these generic: no private dashboard, reverse-proxy, host, or domain coupling unless the module explicitly models that concern.
- `disko/` — disk layouts and install-time storage definitions.
- `pkgs/` — local packages and wrappers. `flake.nix` auto-discovers package files and directories from here.
- `checks/` — flake checks and mechanical repository invariants.
- `secrets/` — agenix encrypted secrets and the secret registry. Plaintext secret material must not be committed.
- `assets/` / `patches/` — static assets and patches consumed by packages or profiles.
- `docs/` — durable guidance for humans and agents.

## Flake model

The main stable pin is `nixpkgs`; `nixpkgs-unstable` is also available. Stable hosts can access `pkgs.unstable.*` through the overlay in `profiles/nixos/base.nix`. `trajanus` is based on `nixpkgs-unstable`, so `pkgs.*` is already unstable there.

Local packages are discovered from `pkgs/` and exposed through `packages.<system>`. Some local packages intentionally wrap or patch upstream projects; prefer small, inspectable packaging changes with comments explaining platform limits or upstream quirks.

New files imported by the flake must be tracked by Git before `nix eval`, `nix build`, or `nix flake check` can reliably see them from the flake source snapshot.

## Host/profile/module boundaries

Prefer this direction of dependency:

```text
hosts -> profiles -> modules/packages -> nixpkgs inputs
```

Guidelines:

- Put host-specific decisions in `hosts/<host>.nix`.
- Put infrastructure composition in `profiles/nixos/` or `profiles/darwin/`.
- Put reusable options and service units in `modules/nixos/`.
- Put build logic in `pkgs/`.
- Put assertions and smoke tests in `checks/` when a recurring rule can be checked mechanically.

Before hand-rolling a systemd service, check whether nixpkgs already provides a NixOS module under `services.*`; prefer upstream modules when they fit.

## Public/private service shape

This repo is public, so keep service definitions deliberate about public exposure. Generic modules should not know about this infrastructure's public domains, dashboards, or reverse-proxy policy. Host/profile layers are the right place for exposure, ACME, Tailscale, dashboard, and routing choices.

Hostname-scoped naming is preferred for infrastructure services because it makes ownership and deployment targets clear.

## Secrets

Encrypted `*.age` files and `secrets/secrets.nix` are the canonical secret model. Use `secrets/README.md` for the workflow. Never commit decrypted material, private keys, copied `.env` files, or command transcripts that include secrets.
