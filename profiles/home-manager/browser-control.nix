{
  lib,
  pkgs,
  ...
}:

let
  cloakBrowser = pkgs.cloakbrowser;
  ketchCli = pkgs.ketch;
in
{
  home = {
    packages = [
      cloakBrowser
      ketchCli
    ];

    sessionVariables = {
      # CloakBrowser's proprietary Chromium binary is fetched by Nix as an
      # unfree, non-redistributable package and used via explicit override.
      CLOAKBROWSER_AUTO_UPDATE = "false";
      CLOAKBROWSER_BINARY_PATH = cloakBrowser.chromiumExecutable;
      # Nix pins Ketch; suppress its ambient release check and update advice.
      KETCH_NO_UPDATE_NOTIFIER = "1";
    };

    file = lib.mkIf pkgs.stdenv.isDarwin {
      ".agent-browser/config.json".text = builtins.toJSON {
        executablePath = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser";
      };

      # ~/.local/bin precedes Homebrew and the nix-darwin user profile, so
      # these reviewed builds remain authoritative even before a full system
      # switch updates /etc/profiles/per-user.
      ".local/bin/ketch".source = lib.getExe ketchCli;

      ".pi/agent/skills/ketch" = {
        source = "${ketchCli}/share/ketch/skill";
        recursive = true;
      };

    };

    activation = {
      ketchStateHardening = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        lib.optionalString pkgs.stdenv.isDarwin ''
          ketchConfigDir="$HOME/Library/Application Support/ketch"
          ketchConfig="$ketchConfigDir/config.json"

          if [ -d "$ketchConfigDir" ]; then
            $DRY_RUN_CMD chmod 0700 "$ketchConfigDir"
          fi
          if [ -f "$ketchConfig" ]; then
            $DRY_RUN_CMD chmod 0600 "$ketchConfig"
          fi
        ''
      );
    };
  };
}
