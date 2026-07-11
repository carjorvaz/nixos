{
  config,
  lib,
  pkgs,
  ...
}:

let
  cloakBrowser = pkgs.cloakbrowser;
  surfCli = pkgs.surf-cli;
  # Keep vanilla Pi's Ketch instructions on the same upstream release as the
  # Homebrew binary without exposing them through the cross-harness
  # ~/.agents/skills discovery path.
  ketchSkillVersion = "0.11.0";
  ketchSource = pkgs.fetchFromGitHub {
    owner = "1broseidon";
    repo = "ketch";
    rev = "v${ketchSkillVersion}";
    hash = "sha256-QTi29NIeJbWF3JG2S1FKTK5V/Qwbj7+wcZjswoW/Bjc=";
  };

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

        ".pi/agent/skills/ketch" = {
          source = "${ketchSource}/skills/ketch";
          recursive = true;
        };

        ".pi/agent/skills/surf" = {
          source = surfCli.surfSkill;
          recursive = true;
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

      ketchSkillVersionCheck = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        lib.optionalString pkgs.stdenv.isDarwin ''
          if [ -x /opt/homebrew/bin/ketch ]; then
            installedVersion="$(
              /opt/homebrew/bin/ketch --version 2>/dev/null \
                | ${pkgs.coreutils}/bin/head -n 1
            )"

            if [ "$installedVersion" != "ketch v${ketchSkillVersion}" ]; then
              echo "warning: Ketch skill is pinned to v${ketchSkillVersion}, but $installedVersion is installed" >&2
            fi
          fi
        ''
      );
    };
  };
}
