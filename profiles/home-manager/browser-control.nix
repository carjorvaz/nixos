{
  config,
  lib,
  pkgs,
  ...
}:

let
  cloakBrowser = pkgs.cloakbrowser;
  cloakBrowserChromium = pkgs.cloakbrowser-chromium;
  cloakBrowserChromiumExecutable = "${cloakBrowserChromium}/Applications/Chromium.app/Contents/MacOS/Chromium";
  cloakBrowserEnv = ''
    export CLOAKBROWSER_AUTO_UPDATE="''${CLOAKBROWSER_AUTO_UPDATE:-false}"
    export CLOAKBROWSER_BINARY_PATH="''${CLOAKBROWSER_BINARY_PATH:-${cloakBrowserChromiumExecutable}}"
  '';
  cloakBrowserCli = pkgs.writeShellApplication {
    name = "cloakbrowser";
    text = ''
      ${cloakBrowserEnv}
      exec ${cloakBrowser}/bin/cloakbrowser "$@"
    '';
  };
  cloakBrowserPython = pkgs.python3.withPackages (ps: [
    (ps.toPythonModule cloakBrowser)
  ]);
  cloakBrowserPythonCli = pkgs.writeShellApplication {
    name = "cloakbrowser-python";
    text = ''
      ${cloakBrowserEnv}
      exec ${cloakBrowserPython}/bin/python "$@"
    '';
  };
  cloakBrowserSmoke = pkgs.writeShellApplication {
    name = "cloakbrowser-smoke";
    text = ''
      ${cloakBrowserEnv}
      exec ${cloakBrowserPython}/bin/python - <<'PY'
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
  surfCli = pkgs.surf-cli;
  surfExtensionHomePath =
    if pkgs.stdenv.isDarwin then
      "Library/Application Support/surf-cli/chrome-extension"
    else
      ".local/share/surf-cli/chrome-extension";

  surfDarwinNativeMessagingHostDirs = [
    "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
    "Library/Application Support/Google/Chrome/NativeMessagingHosts"
    "Library/Application Support/Chromium/NativeMessagingHosts"
    "Library/Application Support/Microsoft Edge/NativeMessagingHosts"
    "Library/Application Support/Arc/User Data/NativeMessagingHosts"
    "Library/Application Support/net.imput.helium/NativeMessagingHosts"
  ];
  surfDarwinNativeMessagingHostDirsArgs = lib.escapeShellArgs surfDarwinNativeMessagingHostDirs;

  surfNativeMessagingHostManifest = pkgs.writeText "surf.browser.host.json" (
    builtins.toJSON {
      name = "surf.browser.host";
      description = "Surf CLI Native Host";
      path = "${surfCli.nativeHost}/bin/surf-browser-native-host";
      type = "stdio";
      allowed_origins = [
        "chrome-extension://${surfCli.extensionId}/"
      ];
    }
  );
in
{
  home = {
    packages = [
      cloakBrowserChromium
      cloakBrowserCli
      cloakBrowserPythonCli
      cloakBrowserSmoke
      surfCli
    ];

    sessionVariables = {
      # CloakBrowser's proprietary Chromium binary is fetched by Nix as an
      # unfree, non-redistributable package and used via explicit override.
      CLOAKBROWSER_AUTO_UPDATE = "false";
      CLOAKBROWSER_BINARY_PATH = cloakBrowserChromiumExecutable;
      SURF_EXTENSION_PATH = "${config.home.homeDirectory}/${surfExtensionHomePath}";
    };

    # Expose Surf's unpacked extension at a stable home path so the one-time
    # manual browser load does not depend on a GC-able /nix/store path. Keep the
    # top-level path as a real directory tree; Chromium-family browsers can be
    # unreliable when the unpacked extension root itself is a symlink.
    file = lib.mkIf pkgs.stdenv.isDarwin {
      ".agent-browser/config.json".text = builtins.toJSON {
        executablePath = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";
      };

      "${surfExtensionHomePath}" = {
        source = surfCli.chromeExtension;
        recursive = true;
      };
    };

    activation = {
      surfChromeExtensionPathMigration = lib.hm.dag.entryBefore [ "checkLinkTargets" ] (
        lib.optionalString pkgs.stdenv.isDarwin ''
          surfExtensionPath="$HOME/${surfExtensionHomePath}"

          if [ -L "$surfExtensionPath" ]; then
            $DRY_RUN_CMD rm "$surfExtensionPath"
          fi
        ''
      );

      surfChromiumNativeMessagingHosts = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        lib.optionalString pkgs.stdenv.isDarwin ''
          for surfHostDirRel in ${surfDarwinNativeMessagingHostDirsArgs}; do
            surfHostDir="$HOME/$surfHostDirRel"
            surfHostFile="$surfHostDir/surf.browser.host.json"

            $DRY_RUN_CMD mkdir -p "$surfHostDir"
            $DRY_RUN_CMD rm -f "$surfHostFile"
            $DRY_RUN_CMD install -m 0644 ${surfNativeMessagingHostManifest} "$surfHostFile"
          done
        ''
      );
    };
  };
}
