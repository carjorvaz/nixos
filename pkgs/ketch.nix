{
  buildGoModule,
  fetchFromGitHub,
  lib,
}:

let
  version = "0.11.0";
in
buildGoModule {
  pname = "ketch";
  inherit version;

  src = fetchFromGitHub {
    owner = "1broseidon";
    repo = "ketch";
    tag = "v${version}";
    hash = "sha256-QTi29NIeJbWF3JG2S1FKTK5V/Qwbj7+wcZjswoW/Bjc=";
  };

  # Keep API-key config private, update the HTML parser past current Go
  # advisories, and make agent search fan-out respect provider rate limits.
  patches = [ ../patches/ketch-local-hardening.patch ];

  vendorHash = "sha256-YOmo6IziCteJASYmr03JR1/yL5nyVwN4IqgRCl5o/Js=";

  env.CGO_ENABLED = 0;

  ldflags = [
    "-s"
    "-w"
    "-X github.com/1broseidon/ketch/cmd.version=v${version}"
    "-X github.com/1broseidon/ketch/cmd.commit=b04a2fa"
  ];

  postInstall = ''
    mkdir -p "$out/share/ketch"
    cp -R skills/ketch "$out/share/ketch/skill"
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    test "$("$out/bin/ketch" --version)" = "ketch v${version}"
    grep -Fq "Search fan-out is sequential by default" \
      "$out/share/ketch/skill/SKILL.md"

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
