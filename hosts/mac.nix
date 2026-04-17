{
  self,
  lib,
  pkgs,
  inputs,
  ...
}:

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
    hyperfine
    ripgrep
    ripgrep-all
    uutils-coreutils-noprefix

    brainworkshop

    android-tools
    delta
    fzf
    hugo
    go
    neovim
    wget
    yt-dlp
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  nixpkgs.config.allowUnfreePredicate =
    pkg:
    builtins.elem (lib.getName pkg) [
      "firefox-bin"
      "firefox-bin-unwrapped"
    ];

  homebrew = {
    # STATE: requires manually installing Homebrew: brew.sh
    # If not installed, nix-darwin will instruct on how to install
    enable = true;

    onActivation = {
      autoUpdate = true;
      cleanup = "zap";
      upgrade = true;
    };

    brews = [
      "guile"
      "ollama"
      "pipx"
      "python-tk"
      "rlwrap"
      "sbcl"
      "trash"
      "uv"

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
      # "Davinci Resolve" = 571213070;
      Tailscale = 1475387142;
    };

    taps = [
    ];
  };

  programs.man.enable = true;

  environment.variables = {
    EDITOR = "nvim";
    HOMEBREW_NO_ANALYTICS = "1";
  };

  # Disable press and hold for diacritics.
  # I want to be able to press and hold j and k
  # in VSCode with vim keys to move around.
  system.defaults.NSGlobalDomain.ApplePressAndHoldEnabled = false;

  # https://tonsky.me/blog/monitors/#turn-off-font-smoothing
  # https://www.reddit.com/r/MacOS/comments/16tow2w/psa_turn_off_font_smoothing/
  system.defaults.NSGlobalDomain.AppleFontSmoothing = 2;

  # Keyboard
  system.keyboard.enableKeyMapping = true;
  system.keyboard.remapCapsLockToControl = true;

  security.pam.services.sudo_local.touchIdAuth = true;

  # Required by home-manager.
  users.users.cjv.home = "/Users/cjv";

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
    ];

    home.stateVersion = "23.05";
  };

  ids.gids.nixbld = 350;
  system.primaryUser = "cjv";

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;
}
