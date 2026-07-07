{
  config,
  lib,
  pkgs,
  ...
}:

let
  cloakBrowser = pkgs.cloakbrowser;
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

  surfNativeMessagingHostFiles = lib.listToAttrs (
    map (dir: {
      name = "${dir}/surf.browser.host.json";
      value.source = surfNativeMessagingHostManifest;
    }) surfDarwinNativeMessagingHostDirs
  );
in
{
  home = {
    packages = [
      cloakBrowser
      surfCli
    ];

    sessionVariables = {
      # CloakBrowser's proprietary Chromium binary is fetched by Nix as an
      # unfree, non-redistributable package and used via explicit override.
      CLOAKBROWSER_AUTO_UPDATE = "false";
      CLOAKBROWSER_BINARY_PATH = cloakBrowser.chromiumExecutable;
      SURF_EXTENSION_PATH = "${config.home.homeDirectory}/${surfExtensionHomePath}";
    };

    # Expose Surf's unpacked extension at a stable home path so the one-time
    # manual browser load does not depend on a GC-able /nix/store path. Keep the
    # top-level path as a real directory tree; Chromium-family browsers can be
    # unreliable when the unpacked extension root itself is a symlink.
    file = lib.mkIf pkgs.stdenv.isDarwin (
      {
        ".agent-browser/config.json".text = builtins.toJSON {
          executablePath = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";
        };

        "${surfExtensionHomePath}" = {
          source = surfCli.chromeExtension;
          recursive = true;
        };
      }
      // surfNativeMessagingHostFiles
    );

    activation = {
      surfManagedPathMigration = lib.hm.dag.entryBefore [ "checkLinkTargets" ] (
        lib.optionalString pkgs.stdenv.isDarwin ''
          surfExtensionPath="$HOME/${surfExtensionHomePath}"

          if [ -L "$surfExtensionPath" ]; then
            $DRY_RUN_CMD rm "$surfExtensionPath"
          fi

          for surfHostDirRel in ${surfDarwinNativeMessagingHostDirsArgs}; do
            surfHostFile="$HOME/$surfHostDirRel/surf.browser.host.json"

            if [ -e "$surfHostFile" ] && [ ! -L "$surfHostFile" ]; then
              $DRY_RUN_CMD rm -f "$surfHostFile"
            fi
          done
        ''
      );
    };
  };
}
