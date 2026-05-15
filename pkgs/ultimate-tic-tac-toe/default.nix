{
  lib,
  sbcl,
  makeWrapper,
  stdenvNoCC,
}:

let
  lisp = sbcl.withPackages (
    ps: with ps; [
      cl-who
      bordeaux-threads
      fiveam
      hunchentoot
    ]
  );
in
stdenvNoCC.mkDerivation {
  pname = "ultimate-tic-tac-toe";
  version = "0.1.0";

  src = ./source;

  nativeBuildInputs = [ makeWrapper ];

  doCheck = true;

  checkPhase = ''
    runHook preCheck

    export HOME="$TMPDIR"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    ${lisp}/bin/sbcl --script scripts/test.lisp

    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/share/ultimate-tic-tac-toe" "$out/bin"
    cp -R . "$out/share/ultimate-tic-tac-toe/"

    makeWrapper ${lisp}/bin/sbcl "$out/bin/ultimate-tic-tac-toe" \
      --add-flags "--script $out/share/ultimate-tic-tac-toe/scripts/run.lisp"

    runHook postInstall
  '';

  meta = {
    description = "Server-rendered Ultimate Tic Tac Toe with HTMX";
    homepage = "https://uttt.vaz.one";
    license = lib.licenses.agpl3Plus;
    mainProgram = "ultimate-tic-tac-toe";
    platforms = lib.platforms.unix;
  };
}
