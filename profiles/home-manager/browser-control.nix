{
  config,
  lib,
  pkgs,
  ...
}:

let
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
    packages = [ surfCli ];

    sessionVariables.SURF_EXTENSION_PATH = "${config.home.homeDirectory}/${surfExtensionHomePath}";

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
