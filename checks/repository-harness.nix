{ pkgs, ... }:

let
  repoRoot = ../.;
in
{
  repo-harness-docs = pkgs.runCommand "repo-harness-docs" { } ''
    cd ${repoRoot}

    missing=0
    for path in \
      .gitignore \
      AGENTS.md \
      docs/README.md \
      docs/ARCHITECTURE.md \
      docs/VALIDATION.md \
      docs/TOOLING.md \
      docs/PUBLIC_BOUNDARY.md \
      docs/PLANS.md \
      justfile \
      scripts/validate
    do
      if [ ! -e "$path" ]; then
        echo "missing required harness file: $path" >&2
        missing=1
      fi
    done

    if [ "$missing" -ne 0 ]; then
      exit 1
    fi

    if [ ! -x scripts/validate ]; then
      echo "scripts/validate must be executable" >&2
      exit 1
    fi

    for needle in \
      docs/README.md \
      docs/ARCHITECTURE.md \
      docs/VALIDATION.md \
      docs/TOOLING.md \
      docs/PUBLIC_BOUNDARY.md \
      docs/PLANS.md \
      justfile \
      scripts/validate
    do
      if ! grep -Fq "$needle" AGENTS.md README.org docs/README.md docs/VALIDATION.md docs/PLANS.md; then
        echo "harness guidance should mention $needle" >&2
        exit 1
      fi
    done

    if ! grep -Fxq ".jj/" .gitignore; then
      echo ".gitignore must keep colocated Jujutsu state local with .jj/" >&2
      exit 1
    fi

    for needle in \
      jujutsu \
      difftastic \
      just
    do
      if ! grep -Fq "$needle" flake.nix; then
        echo "dev shell should expose high-leverage tool: $needle" >&2
        exit 1
      fi
    done

    for needle in \
      jj-status: \
      jj-diff: \
      jj-ops:
    do
      if ! grep -Fq "$needle" justfile; then
        echo "justfile should expose JJ recipe: $needle" >&2
        exit 1
      fi
    done

    for needle in \
      "jj status" \
      "jj diff" \
      "jj bookmark move" \
      "Git/GitHub"
    do
      if ! grep -Fq "$needle" docs/TOOLING.md; then
        echo "docs/TOOLING.md should document JJ/Git boundary: $needle" >&2
        exit 1
      fi
    done

    if grep -Fq 'WEBUI_AUTH = "False";' profiles/nixos/open-webui.nix \
      && ! grep -Fq 'host = "127.0.0.1";' profiles/nixos/open-webui.nix; then
      echo "open-webui WEBUI_AUTH=False requires loopback host guard" >&2
      exit 1
    fi

    for needle in \
      "searx-health = {" \
      "timers.searx-health = {" \
      /var/lib/searx-health/health.json \
      unresponsive_engines
    do
      if ! grep -Fq "$needle" profiles/nixos/searx.nix; then
        echo "searx health monitor missing: $needle" >&2
        exit 1
      fi
    done

    touch $out
  '';

}
