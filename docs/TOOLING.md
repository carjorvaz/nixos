# Tooling

This repo prefers sharp tools when they make agent and human work more mechanically legible. Do not add clever tools for novelty; add tools when they improve validation, recoverability, reproducibility, or review.

## Default command surface

Use the flake dev shell when a tool may not be installed globally:

```sh
nix develop -c just --list
nix develop -c just validate
```

`just` is only an ergonomic menu. Keep canonical logic in `scripts/validate`, flake checks, or focused scripts so humans, Codex, Hermes, and CI-like checks call the same entrypoints.

## Local history workflow

Use Jujutsu (`jj`) as the preferred local history/editing interface for this personal repo:

```sh
nix develop -c jj status
nix develop -c jj diff
nix develop -c jj log
nix develop -c jj split
nix develop -c jj squash -i
nix develop -c jj op log
nix develop -c jj undo
```

Keep Git/GitHub as the publication and compatibility layer:

```sh
git status -sb
git push
git tag -a vX.Y.Z <commit> -m "release"
gh run list
```

In this flake repo, remember that new files imported by Nix must be Git-tracked before flake evaluation sees them. When adding a new Nix-imported file, add it to Git before trusting `nix eval`, `nix build`, or `scripts/validate`.

## Review surface

Prefer structural, high-signal review tools where available:

- `difftastic` for non-trivial code diffs;
- `nixfmt`/`treefmt` for formatting rather than manual whitespace cleanup;
- `statix` and `deadnix` as advisory Nix cleanup tools, not automatic proof of correctness.

Do not make sharp tools competing sources of truth. Nix owns the environment, `scripts/validate` owns default validation, `justfile` exposes the menu, JJ owns local change manipulation, and Git owns remote publication.
