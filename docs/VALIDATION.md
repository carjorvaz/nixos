# Validation

Use `scripts/validate` as the default local validation entrypoint before committing or deploying changes.

```sh
scripts/validate
```

For a discoverable task menu with repository tools on machines that do not have
them installed globally, enter the dev shell and use the `justfile`:

```sh
nix develop -c just --list
nix develop -c just validate
```

The default validation is intentionally public-safe and non-mutating. It does not SSH to hosts, deploy, decrypt secrets, switch systems, or print full evaluated configurations. Nix may still use normal fetchers for flake inputs.

## What the default command checks

- `git diff --check HEAD --` for whitespace errors across staged and unstaged changes.
- `nix flake show --allow-import-from-derivation --no-write-lock-file` for flake shape.
- `nix eval` of each NixOS host's `config.system.build.toplevel.drvPath`.
- `nix eval` of the nix-darwin `air` system output.
- `nix eval` of the current-system check names.
- `nix build --no-link` of the lightweight current-system `repo-harness-docs` check.
- `nix eval` of the `checks.x86_64-linux` check names.

This is a good default for agent work on macOS because it catches most structural errors without attempting Linux builds locally.

## Optional stronger checks

Dry-run all x86_64-linux flake checks without building them:

```sh
scripts/validate --dry-run-checks
```

Build or run individual checks only when the local machine or configured builders can support them:

```sh
nix build --no-link .#checks.aarch64-darwin.repo-harness-docs  # on Apple Silicon Macs
nix build --no-link .#checks.x86_64-linux.repo-harness-docs    # on Linux or a Linux builder
nix build --no-link .#checks.x86_64-linux.firecrawl-module-generic-quality
nix build --no-link .#checks.x86_64-linux.firecrawl-unsafe-bind-rejected
```

The Firecrawl VM smoke test is heavier and Linux-specific:

```sh
nix build --no-link .#checks.x86_64-linux.firecrawl-nixos-smoke
```

## Deploy and rebuild commands

Deploy/rebuild commands are intentionally not part of default validation. Run them only when you intend to mutate a host:

```sh
nh os test                 # trajanus local test switch, no boot entry
nh os switch               # trajanus local switch
nixos-rebuild boot --flake .#<host> --target-host root@<host>
nixos-rebuild switch --flake .#<host> --target-host root@<host>
```

Prefer `nix eval` and `nix build --dry-run --no-link` before mutating rebuilds.

## Flake source snapshot reminder

If you add a new file that is imported by the flake or checked by Nix, add it to Git before relying on `nix eval`, `nix build`, or `nix flake check`:

```sh
git add path/to/new-file
```

Untracked files are ignored by the flake source snapshot.
