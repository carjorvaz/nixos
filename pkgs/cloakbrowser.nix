{
  callPackage,
  lib,
  runCommand,
  stdenvNoCC,
  writeShellApplication,
  python3,
  cloakbrowserPython ? callPackage ./cloakbrowser-python.nix { },
  cloakbrowserChromium ? callPackage ./cloakbrowser-chromium.nix { },
}:

let
  inherit (cloakbrowserPython) version;

  chromiumExecutable = "${cloakbrowserChromium}/Applications/Chromium.app/Contents/MacOS/Chromium";

  pythonEnv = python3.withPackages (ps: [
    (ps.toPythonModule cloakbrowserPython)
  ]);

  cloakbrowserEnv = ''
    export CLOAKBROWSER_AUTO_UPDATE="''${CLOAKBROWSER_AUTO_UPDATE:-false}"
    export CLOAKBROWSER_BINARY_PATH="''${CLOAKBROWSER_BINARY_PATH:-${chromiumExecutable}}"
  '';

  cli = writeShellApplication {
    name = "cloakbrowser";
    text = ''
      ${cloakbrowserEnv}
      exec ${cloakbrowserPython}/bin/cloakbrowser "$@"
    '';
  };

  pythonCli = writeShellApplication {
    name = "cloakbrowser-python";
    text = ''
      ${cloakbrowserEnv}
      exec ${pythonEnv}/bin/python "$@"
    '';
  };

  smoke = writeShellApplication {
    name = "cloakbrowser-smoke";
    text = ''
      ${cloakbrowserEnv}
      exec ${pythonEnv}/bin/python - <<'PY'
      from cloakbrowser import launch

      browser = launch(headless=True)
      try:
          page = browser.new_page()
          page.goto("https://example.com", wait_until="domcontentloaded", timeout=30000)
          print(page.title())
          print(page.locator("h1").inner_text())
      finally:
          browser.close()
      PY
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "cloakbrowser";
  inherit version;

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    ln -s ${cli}/bin/cloakbrowser "$out/bin/cloakbrowser"
    ln -s ${pythonCli}/bin/cloakbrowser-python "$out/bin/cloakbrowser-python"
    ln -s ${smoke}/bin/cloakbrowser-smoke "$out/bin/cloakbrowser-smoke"
    ln -s ${cloakbrowserChromium}/bin/cloakbrowser-chrome "$out/bin/cloakbrowser-chrome"

    runHook postInstall
  '';

  passthru = {
    inherit chromiumExecutable pythonEnv;
    pythonPackage = cloakbrowserPython;
    chromium = cloakbrowserChromium;

    tests = {
      help = runCommand "cloakbrowser-help-test" { } ''
        ${cli}/bin/cloakbrowser --help > help.txt
        grep -q 'Manage the CloakBrowser stealth Chromium binary' help.txt
        touch "$out"
      '';

      import = runCommand "cloakbrowser-import-test" { } ''
        ${pythonEnv}/bin/python - <<'PY'
        import cloakbrowser
        assert cloakbrowser.__name__ == "cloakbrowser"
        PY
        touch "$out"
      '';
    };
  };

  meta = {
    description = "Stealth Chromium wrapper and CLI for Playwright automation";
    homepage = "https://github.com/CloakHQ/CloakBrowser";
    license = [
      lib.licenses.mit
      cloakbrowserChromium.meta.license
    ];
    mainProgram = "cloakbrowser";
    platforms = cloakbrowserChromium.meta.platforms;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
