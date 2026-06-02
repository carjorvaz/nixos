# Tooling

This repo prefers high-leverage tools when they make agent and human work more mechanically legible. Do not add clever tools for novelty; add tools when they improve validation, recoverability, reproducibility, or review.

## Default command surface

Use the flake dev shell when a tool may not be installed globally:

```sh
nix develop -c just --list
nix develop -c just validate
```

`just` is only an ergonomic menu. Keep canonical logic in `scripts/validate`, flake checks, or focused scripts so humans, Hermes, and other agents call the same entrypoints.

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

For normal agent work, start from `jj status` and `jj diff`, then use `jj` to shape local history. If a change is ready for `master`, commit through JJ and explicitly move the bookmark before using Git to publish:

```sh
nix develop -c jj commit -m "Concise change summary"
nix develop -c jj bookmark move master --to @-
git push origin master
nix develop -c jj status
```

If a workflow still uses `git commit` directly, run `nix develop -c jj status` afterwards so JJ imports the Git commit and verifies the working-copy parent is aligned. Do not treat Git's detached-looking view inside a colocated JJ repo as the source of truth; verify bookmarks and remote refs before reporting a pushed branch clean.

In this flake repo, remember that new files imported by Nix must be Git-tracked before flake evaluation sees them. When adding a new Nix-imported file, add it to Git before trusting `nix eval`, `nix build`, or `scripts/validate`.

## Review surface

Prefer structural, high-signal review tools where available:

- `difftastic` for non-trivial code diffs;
- `nixfmt`/`treefmt` for formatting rather than manual whitespace cleanup;
- `statix` and `deadnix` as advisory Nix cleanup tools, not automatic proof of correctness.

Do not make tooling layers compete as sources of truth. Nix owns the environment, `scripts/validate` owns default validation, `justfile` exposes the menu, JJ owns local change manipulation, and Git owns remote publication.
