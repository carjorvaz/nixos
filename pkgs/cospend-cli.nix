{
  lib,
  makeWrapper,
  python3,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation {
  pname = "cospend-cli";
  version = "0.1.0";

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    cp ${./cospend-cli.py} cospend-cli.py
    cp ${./cospend-cli-test.py} cospend-cli-test.py
    ${python3}/bin/python3 cospend-cli-test.py
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 ${./cospend-cli.py} $out/libexec/cospend-cli.py
    makeWrapper ${python3}/bin/python3 $out/bin/cospendctl \
      --add-flags $out/libexec/cospend-cli.py
    runHook postInstall
  '';

  meta = {
    description = "Preview-first client for a least-privilege Cospend expense bot";
    license = lib.licenses.mit;
    mainProgram = "cospendctl";
    platforms = lib.platforms.darwin;
  };
}
