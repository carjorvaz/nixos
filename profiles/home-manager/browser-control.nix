{
  config,
  lib,
  pkgs,
  ...
}:

let
  cloakBrowser = pkgs.cloakbrowser;
  ketchCli = pkgs.ketch;
  surfCli = pkgs.surf-cli;

  surfExtensionHomePath = "Library/Application Support/surf-cli/chrome-extension";

  surfDarwinNativeMessagingHostDirs = [
    # Current Brave releases discover user-level native hosts through Chrome's
    # compatibility directory on macOS. The manifest is still pinned to Surf's
    # extension ID, and that extension loads only in the dedicated Brave profile.
    "Library/Application Support/Google/Chrome/NativeMessagingHosts"
  ];
  surfDarwinNativeMessagingHostDirsArgs = lib.escapeShellArgs surfDarwinNativeMessagingHostDirs;
  surfDarwinLegacyNativeMessagingHostDirsArgs = lib.escapeShellArgs [
    "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
  ];

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

  # Surf has debugger, cookie, history, bookmark, download, and all-URL access.
  # Keep that authority in a dedicated non-syncing browser profile rather than
  # loading the extension into a daily browser profile.
  surfBrowser = pkgs.writeShellApplication {
    name = "surf-browser";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      profileRoot="''${XDG_DATA_HOME:-$HOME/.local/share}/surf-browser"

      install -d -m 0700 "$profileRoot"
      exec "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
        --user-data-dir="$profileRoot" \
        --disable-sync \
        --disable-extensions-except="${surfCli.chromeExtension}" \
        --load-extension="${surfCli.chromeExtension}" \
        --no-first-run \
        --no-default-browser-check \
        "$@"
    '';
  };
in
{
  home = {
    packages = [
      cloakBrowser
      ketchCli
      surfBrowser
      surfCli
    ];

    sessionVariables = {
      # CloakBrowser's proprietary Chromium binary is fetched by Nix as an
      # unfree, non-redistributable package and used via explicit override.
      CLOAKBROWSER_AUTO_UPDATE = "false";
      CLOAKBROWSER_BINARY_PATH = cloakBrowser.chromiumExecutable;
      # Nix pins Ketch; suppress its ambient release check and update advice.
      KETCH_NO_UPDATE_NOTIFIER = "1";
      SURF_EXTENSION_PATH = "${surfCli.chromeExtension}";
      SURF_STATE_DIR = "${config.home.homeDirectory}/.local/state/surf";
    };

    # Load Surf's unpacked extension directly from its referenced Nix output;
    # Chromium rejects the recursive per-file symlink tree Home Manager would
    # otherwise create for an unpacked extension.
    file = lib.mkIf pkgs.stdenv.isDarwin (
      {
        ".agent-browser/config.json".text = builtins.toJSON {
          executablePath = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";
        };

        # ~/.local/bin precedes Homebrew and the nix-darwin user profile, so
        # these reviewed builds remain authoritative even before a full system
        # switch updates /etc/profiles/per-user.
        ".local/bin/ketch".source = lib.getExe ketchCli;
        ".local/bin/surf".source = lib.getExe surfCli;
        ".local/bin/surf-browser".source = lib.getExe surfBrowser;

        ".pi/agent/skills/ketch" = {
          source = "${ketchCli}/share/ketch/skill";
          recursive = true;
        };

        ".pi/agent/skills/surf" = {
          source = surfCli.surfSkill;
          recursive = true;
        };
      }
      // surfNativeMessagingHostFiles
    );

    activation = {
      surfManagedPathMigration = lib.hm.dag.entryBefore [ "checkLinkTargets" ] (
        lib.optionalString pkgs.stdenv.isDarwin ''
          surfExtensionPath="$HOME/${surfExtensionHomePath}"

          # Remove the previous recursive-symlink extension tree. The dedicated
          # launcher now references the immutable extension output directly.
          if [ -e "$surfExtensionPath" ] || [ -L "$surfExtensionPath" ]; then
            $DRY_RUN_CMD rm -rf "$surfExtensionPath"
          fi

          for surfHostDirRel in ${surfDarwinNativeMessagingHostDirsArgs}; do
            surfHostFile="$HOME/$surfHostDirRel/surf.browser.host.json"

            if [ -e "$surfHostFile" ] && [ ! -L "$surfHostFile" ]; then
              $DRY_RUN_CMD rm -f "$surfHostFile"
            fi
          done

          # Brave does not read its documented manifest directory in the
          # current macOS build; remove the stale copy left by the old setup.
          for surfHostDirRel in ${surfDarwinLegacyNativeMessagingHostDirsArgs}; do
            surfHostFile="$HOME/$surfHostDirRel/surf.browser.host.json"

            if [ -e "$surfHostFile" ] || [ -L "$surfHostFile" ]; then
              $DRY_RUN_CMD rm -f "$surfHostFile"
            fi
          done
        ''
      );

      researchToolStateHardening = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        lib.optionalString pkgs.stdenv.isDarwin ''
          ketchConfigDir="$HOME/Library/Application Support/ketch"
          ketchConfig="$ketchConfigDir/config.json"
          surfStateDir="$HOME/.local/state/surf"

          if [ -d "$ketchConfigDir" ]; then
            $DRY_RUN_CMD chmod 0700 "$ketchConfigDir"
          fi
          if [ -f "$ketchConfig" ]; then
            $DRY_RUN_CMD chmod 0600 "$ketchConfig"
          fi
          $DRY_RUN_CMD install -d -m 0700 "$surfStateDir" "$surfStateDir/tmp"

          # Old Surf releases wrote browser payloads and screenshots to public
          # /tmp paths. Restrict them immediately; remove them on a later
          # activation once the old native host has stopped and removed its
          # socket.
          if [ -f /tmp/surf-host.log ]; then
            $DRY_RUN_CMD chmod 0600 /tmp/surf-host.log
          fi
          if [ -d /tmp/surf ]; then
            $DRY_RUN_CMD chmod -R go-rwx /tmp/surf
          fi
          if [ ! -S /tmp/surf.sock ]; then
            $DRY_RUN_CMD rm -f /tmp/surf-host.log
            $DRY_RUN_CMD rm -rf /tmp/surf
          fi
        ''
      );
    };
  };
}
