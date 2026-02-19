{ stdenvNoCC }:

stdenvNoCC.mkDerivation {
  pname = "org-dump-extension";
  version = "1.0";

  src = ./.;

  installPhase = ''
    mkdir -p $out
    cp manifest.json background.js $out/
  '';
}
