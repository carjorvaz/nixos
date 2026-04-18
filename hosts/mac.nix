{
  self,
  lib,
  pkgs,
  inputs,
  config,
  ...
}:

let
  key = key_code: { inherit key_code; };
  topCaseKey = apple_vendor_top_case_key_code: { inherit apple_vendor_top_case_key_code; };

  remap = from: to: {
    inherit from;
    to = [ to ];
  };

  swap = a: b: [
    (remap a b)
    (remap b a)
  ];

  keyboard = vendor_id: product_id: {
    identifiers = {
      is_keyboard = true;
      inherit product_id vendor_id;
    };
  };

  builtInAppleIsoKeyboard = keyboard 1452 834;

  leftCommandSwap = swap (key "left_command") (key "left_option");

  globalModifierPolicy =
    [
      (remap (key "right_command") (key "right_option"))
      (remap (key "caps_lock") (key "left_control"))
    ]
    ++ leftCommandSwap;

  karabinerConfig = {
    global.show_in_menu_bar = false;

    profiles = [
      {
        name = "Default profile";
        selected = true;

        simple_modifications = globalModifierPolicy;

        devices = [
          ((builtInAppleIsoKeyboard) // {
            simple_modifications = [
              (remap (topCaseKey "keyboard_fn") (key "left_control"))
              (remap (key "left_control") (topCaseKey "keyboard_fn"))
              (remap (key "left_command") (key "left_command"))
              (remap (key "left_option") (key "left_option"))
            ];
          })
        ];

        virtual_hid_keyboard.keyboard_type_v2 = "iso";
      }
    ];
  };

  karabinerJson = pkgs.writeText "karabiner.json" (builtins.toJSON karabinerConfig);

  karabinerConfigDir = pkgs.runCommandLocal "karabiner-config" { } ''
    mkdir -p "$out/assets/complex_modifications"
    cp ${karabinerJson} "$out/karabiner.json"
  '';

  fontconfigMacosConf = pkgs.writeText "fontconfig-macos-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <dir>/Library/Fonts</dir>
      <dir>/System/Library/Fonts</dir>
      <dir>~/Library/Fonts</dir>
    </fontconfig>
  '';
in

# Bootstrapping:
# 1. Install Nix with determinate installer (install upstream Nix, not Determinate Nix)
#   curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
# 2. Use nix run to run the first rebuild
#   nix run nix-darwin -- switch --flake ~/Documents/nixos#mac
# 3. Use darwin-rebuild normally
#   darwin-rebuild switch --flake ~/Documents/nixos#mac

# References:
# - https://gist.github.com/jmatsushita/5c50ef14b4b96cb24ae5268dab613050
# - https://github.com/LnL7/nix-darwin
#   - https://daiderd.com/nix-darwin/manual/index.html#sec-options
{
  home-manager.backupFileExtension = "hm-backup";

  imports = [
    "${self}/profiles/darwin/emacs.nix"
    "${self}/profiles/darwin/fish.nix"
  ];

  nix = {
    enable = true;

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      substituters = [ "https://cache.numtide.com" ];
      trusted-public-keys = [ "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=" ];
    };

    registry = {
      nixpkgs.flake = inputs.nixpkgs-darwin;
      unstable.flake = inputs.nixpkgs-unstable;
    };

    extraOptions = lib.optionalString (pkgs.stdenv.hostPlatform.system == "aarch64-darwin") ''
      extra-platforms = x86_64-darwin aarch64-darwin
    '';
  };

  networking.hostName = "mac";

  fonts.packages = [
    pkgs.nerd-fonts.jetbrains-mono
    pkgs.nerd-fonts.symbols-only
    pkgs.symbola
  ];

  environment.etc = {
    "fonts/fonts.conf".source = "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
    "fonts/conf.d/50-macos-fonts.conf".source = fontconfigMacosConf;
  };

  environment.systemPackages = with pkgs; [
    colima # Streamlines Docker, just run `colima start`.
    docker
    ghostty-bin
    htop
    firefox-bin
    freerdp
    llama-cpp
    nixos-rebuild
    signal-desktop
    telegram-desktop
    vesktop-discord

    delta
    dua
    fd
    gh
    hyperfine
    ripgrep-all
    uutils-coreutils-noprefix

    brainworkshop

    android-tools
    fzf
    hugo
    go
    guile
    neovim
    pipx
    rlwrap
    sbcl
    uv
    wget
    yt-dlp
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default

    # HM's mpv module doesn't support package = null, so reference its
    # finalPackage to land mpv.app in /Applications/Nix Apps without
    # duplicating the override from profiles/home-manager/mpv.nix.
    config.home-manager.users.cjv.programs.mpv.finalPackage
  ];

  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "firefox-bin"
      "firefox-bin-unwrapped"
      "symbola"
    ];

  homebrew = {
    # STATE: requires manually installing Homebrew: brew.sh
    # If not installed, nix-darwin will instruct on how to install
    enable = true;
    # Keep Homebrew on PATH declaratively instead of shelling out to
    # `brew shellenv` during Fish startup. cmux's embedded Ghostty layer can
    # currently hit a PermissionDenied opening TCC-protected cwd paths under
    # ~/Documents, which then breaks the shellenv hook and leaves Fish without
    # `brew` on PATH.
    enableFishIntegration = false;

    onActivation = {
      autoUpdate = true;
      cleanup = "uninstall";
      upgrade = true;
    };

    brews = [
      "trash"
    ];

    # Update these applicatons manually.
    # As brew would update them by unninstalling and installing the newest
    # version, it could lead to data loss.
    casks = [
      "balenaetcher"
      "brave-browser"
      "claude-code@latest"
      "cmux"
      "comfyui"
      "codex"
      "flux-app"
      "karabiner-elements" # STATE: Rebind right-command to right-option
      "keepingyouawake" # Simple open-source menu bar wrapper around caffeinate. If I want a more custom toggle later, SwiftBar plus a small plugin is a good fallback.
      # "microsoft-office" # Only have installed when needed (has some sinister telemetry).
      "microsoft-teams" # Only have installed when needed (has some sinister telemetry).
      # "monitorcontrol" # Brightness and volume controls for external monitors.
      "orcaslicer"
      "orion"
      "stremio"
      "stillcolor"
      "syncthing-app"
      "transmission"
      "trader-workstation"
      # "tunnelblick" # OpenVPN client - re-enable if needed.
      "ukelele"
      "unnaturalscrollwheels"
      "utm"
      "whatsapp"
      "zed@preview"
      "zoom"
    ];

    masApps = {
      # STATE:
      # - Enable browser extension
      # - Match URI by host
      # - Unlock with biometrics, both in extension settings and desktop app settings
      # - Enable browser integration in desktop app settings)
      Bitwarden = 1352778147;
      "Davinci Resolve" = 571213070;
      Tailscale = 1475387142;
      "uBlock Origin Lite" = 6745342698;
    };

    taps = [
    ];
  };

  programs.man.enable = true;

  environment.variables = {
    EDITOR = "nvim";
    GHOSTTY_RESOURCES_DIR = "${pkgs.ghostty-bin}/Applications/Ghostty.app/Contents/Resources/ghostty";
    HOMEBREW_CELLAR = "/opt/homebrew/Cellar";
    HOMEBREW_NO_ANALYTICS = "1";
    HOMEBREW_PREFIX = "/opt/homebrew";
    HOMEBREW_REPOSITORY = "/opt/homebrew";
  };

  # Disable press and hold for diacritics.
  # I want to be able to press and hold j and k
  # in VSCode with vim keys to move around.
  system.defaults.NSGlobalDomain.ApplePressAndHoldEnabled = false;

  # https://tonsky.me/blog/monitors/#turn-off-font-smoothing
  # https://www.reddit.com/r/MacOS/comments/16tow2w/psa_turn_off_font_smoothing/
  system.defaults.NSGlobalDomain.AppleFontSmoothing = 1;

  system.defaults.trackpad = {
    ActuateDetents = true;
    ActuationStrength = 0;
    FirstClickThreshold = 0;
    ForceSuppressed = true;
  };

  # Keyboard
  system.keyboard.enableKeyMapping = true;
  system.keyboard.remapCapsLockToControl = true;

  security.pam.services.sudo_local.touchIdAuth = true;

  # Required by home-manager.
  users.knownUsers = [ "cjv" ];
  users.users.cjv = {
    uid = 501;
    home = "/Users/cjv";
    shell = pkgs.fish;
  };

  home-manager.users.cjv = {
    imports = [
      "${self}/profiles/home-manager/brave.nix"
      "${self}/profiles/home-manager/firefox-mac.nix"
      "${self}/profiles/home-manager/helix.nix"
      "${self}/profiles/home-manager/mpv.nix"
      "${self}/profiles/home-manager/neovim.nix"
      "${self}/profiles/home-manager/ssh.nix"
    ];

    home.sessionPath = [
      # STATE: install juliaup manually with curl method
      "/Users/cjv/.juliaup/bin/"
      "/Users/cjv/.local/bin"
      "/opt/homebrew/bin"
      "/opt/homebrew/sbin"
    ];

    # Ghostty is installed via environment.systemPackages so it lands in
    # /Applications/Nix Apps. package = null avoids HM double-installing it
    # under ~/Applications/Home Manager Apps.
    programs.ghostty = {
      enable = true;
      package = null;
      settings = {
        theme = "light:Gruvbox Light,dark:Gruvbox Dark Hard";
        font-size = 18;
      };
    };

    # cmux only looks in ~/.config/ghostty/themes and /Applications/Ghostty.app
    # for Ghostty themes. Expose the Nix-provided themes at the user path so
    # cmux can pick up Gruvbox and friends while Ghostty itself stays managed
    # via Nix Apps.
    home.file.".config/ghostty/themes".source =
      "${pkgs.ghostty-bin}/Applications/Ghostty.app/Contents/Resources/ghostty/themes";

    # Keep the whole directory store-backed. Karabiner watches the parent
    # directory and warns against symlinking only karabiner.json.
    home.file.".config/karabiner".source = karabinerConfigDir;

    # Keep cmux's embedded browser available for deliberate use, but route
    # automatic link opening to the system browser instead of unexpectedly
    # hijacking terminal links, `open https://...`, PR links, or detected
    # localhost ports.
    home.file.".config/cmux/settings.json" = {
      force = true;
      text = builtins.toJSON {
        app = {
          sendAnonymousTelemetry = false;
        };
        browser = {
          defaultSearchEngine = "kagi";
          openTerminalLinksInCmuxBrowser = false;
          interceptTerminalOpenCommandInCmuxBrowser = false;
        };
        sidebar = {
          openPullRequestLinksInCmuxBrowser = false;
          openPortLinksInCmuxBrowser = false;
        };
      };
    };

    home.activation.karabinerConfigMigration = {
      before = [ "checkLinkTargets" ];
      after = [ ];
      data = ''
        target="$HOME/.config/karabiner"
        backup="$HOME/.config/karabiner.pre-declarative"

        if [ -e "$target" ] && [ ! -L "$target" ]; then
          if [ -e "$backup" ]; then
            echo "Refusing to replace $target because $backup already exists." >&2
            exit 1
          fi

          $DRY_RUN_CMD mv "$target" "$backup"
        fi
      '';
    };

    home.activation.karabinerReload = {
      before = [ ];
      after = [ "writeBoundary" ];
      data = ''
        if /bin/launchctl print "gui/$UID/org.pqrs.service.agent.karabiner_console_user_server" >/dev/null 2>&1; then
          $DRY_RUN_CMD /bin/launchctl kickstart -k "gui/$UID/org.pqrs.service.agent.karabiner_console_user_server"
        elif /bin/launchctl print "gui/$UID/org.pqrs.karabiner.karabiner_console_user_server" >/dev/null 2>&1; then
          $DRY_RUN_CMD /bin/launchctl kickstart -k "gui/$UID/org.pqrs.karabiner.karabiner_console_user_server"
        fi
      '';
    };

    home.stateVersion = "23.05";
  };

  programs.fish.interactiveShellInit = lib.mkAfter ''
    if test -d "/opt/homebrew/share/fish/completions"
      set -p fish_complete_path "/opt/homebrew/share/fish/completions"
    end
    if test -d "/opt/homebrew/share/fish/vendor_completions.d"
      set -p fish_complete_path "/opt/homebrew/share/fish/vendor_completions.d"
    end
  '';

  # cmux still ships without Ghostty shell integration files. Link the Nix
  # Ghostty integration into the app bundle so shells spawned from cmux get the
  # usual prompt marks and cwd reporting.
  system.activationScripts.postActivation.text = ''
    cmux="/Applications/cmux.app/Contents/Resources/ghostty"
    si="${pkgs.ghostty-bin}/Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration"
    target="$cmux/shell-integration"

    if [ -d "$cmux" ] && [ -d "$si" ] && { [ ! -e "$target" ] || [ -L "$target" ]; }; then
      ln -sfn "$si" "$target"
    fi

    # Brave reads managed preferences from this path, but off-store
    # force-installed extensions are blocked on unmanaged macOS browsers.
    # Remove any previous plist so brave://policy stops showing stale blocked
    # Rustab/BPC entries after we move back to the supported manual path here.
    rm -f "/Library/Managed Preferences/cjv/com.brave.Browser.plist"
    /usr/bin/killall cfprefsd 2>/dev/null || true
  '';

  ids.gids.nixbld = 350;
  system.primaryUser = "cjv";

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;
}
