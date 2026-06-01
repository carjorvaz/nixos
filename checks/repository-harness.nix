{ pkgs, ... }:

let
  repoRoot = ../.;
in
{
  repo-harness-docs = pkgs.runCommand "repo-harness-docs" { } ''
    cd ${repoRoot}

    missing=0
    for path in \
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

    touch $out
  '';
}
