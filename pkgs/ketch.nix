{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:

let
  version = "0.16.2";
  revision = "2ae1fba162c116dea6e08fc65d98f2acdd30296b";
in
buildGoModule {
  pname = "ketch";
  inherit version;

  src = fetchFromGitHub {
    owner = "1broseidon";
    repo = "ketch";
    rev = revision;
    hash = "sha256-kkRscQAO29jbDAYJKN3SXDdZu9XV0D9ylC3WyqW+pTU=";
  };

  # No application-source patches. Upstream now protects config/cache files.
  # Keep its HTML/Unicode dependencies past GO-2026-5028 / GO-2026-5970;
  # remove these packaging-only pins once upstream catches up.
  postPatch = ''
    go mod edit -go=1.26.0 \
      -require=golang.org/x/net@v0.59.0 \
      -require=golang.org/x/sys@v0.48.0 \
      -require=golang.org/x/text@v0.42.0
  '';
  overrideModAttrs = _: {
    # Network access belongs only in the fixed-output dependency fetch.
    preBuild = "go mod tidy";
  };

  vendorHash = "sha256-q3EPiIsEA2mp4mOiA6aca3UAARyh4g5PUlT9xYWvhS4=";

  # Do not ship upstream's unrelated cmd/readtest development executable.
  subPackages = [ "." ];
  checkPhase = ''
    runHook preCheck
    # A subprocess-auth fixture has a two-second deadline; avoid competing
    # package test processes making it flaky on macOS builders.
    go test -p 1 ./...
    runHook postCheck
  '';

  env.CGO_ENABLED = 0;

  ldflags = [
    "-s"
    "-w"
    "-X github.com/1broseidon/ketch/cmd.version=v${version}"
    "-X github.com/1broseidon/ketch/cmd.commit=${lib.substring 0 7 revision}"
  ];

  postInstall = ''
    mkdir -p "$out/share/ketch"
    cp -R skills/ketch "$out/share/ketch/skill"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    test "$("$out/bin/ketch" --version)" = "ketch v${version}"
    test -f "$out/share/ketch/skill/SKILL.md"
    test -f "$out/share/ketch/skill/references/verbs/ketch-research.md"
    test ! -e "$out/bin/readtest"

    runHook postInstallCheck
  '';

  meta = {
    description = "Stateless web, code, and documentation research CLI";
    homepage = "https://github.com/1broseidon/ketch";
    license = lib.licenses.mit;
    mainProgram = "ketch";
    platforms = lib.platforms.unix;
  };
}
