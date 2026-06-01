set shell := ["bash", "-euo", "pipefail", "-c"]

# Show available repository tasks
_default:
    @just --list

# Run the public-safe non-mutating validation harness
validate:
    ./scripts/validate

# Validate one NixOS host's toplevel evaluation
validate-host host:
    ./scripts/validate --host {{host}}

# Run validation plus dry-run checks for x86_64-linux check attributes
validate-dry:
    ./scripts/validate --dry-run-checks

# Show flake outputs without writing the lock file
show:
    nix flake show --allow-import-from-derivation --no-write-lock-file

# List check attributes for the current system
checks:
    nix eval --json ".#checks.$(nix eval --raw --impure --expr 'builtins.currentSystem')" --apply 'builtins.attrNames'

# Check formatting of tracked Nix files without rewriting them
fmt-check:
    nixfmt --check $(git ls-files '*.nix')

# Run lightweight Nix static analysis; keep advisory, not part of default validation
lint-nix:
    statix check .
    deadnix .
