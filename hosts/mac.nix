{ config, lib, pkgs, inputs, ... }:

# Bootstrapping:
# 1. Install Nix
#   curl -L https://nixos.org/nix/install | sh
# 2. Enable Flakes
#   mkdir -p ~/.config/nix
#   cat <<EOF > ~/.config/nix/nix.conf
#   experimental-features = nix-command flakes
#   EOF
# 3. Use nix run to run the first rebuild
#   nix run nix-darwin -- switch --flake ~/.config/nix-darwin
# 4. Use darwin-rebuild normally
#   darwin-rebuild switch --flake ~/.config/nix-darwin

# References:
# - https://gist.github.com/jmatsushita/5c50ef14b4b96cb24ae5268dab613050
# - https://github.com/LnL7/nix-darwin
#   - https://daiderd.com/nix-darwin/manual/index.html#sec-options
{
  imports = [ ../profiles/home/zsh.nix ];

  # Auto upgrade nix package and the daemon service.
  services.nix-daemon.enable = true;

  nix = {
    package = pkgs.nix;

    gc.automatic = true;
    optimise.automatic = true;
    settings = {
      auto-optimise-store = true;
      experimental-features = [ "nix-command" "flakes" ];
    };

    registry = {
      nixpkgs.flake = inputs.nixpkgs-darwin;
      unstable.flake = inputs.nixpkgs-unstable;
    };

    extraOptions = lib.optionalString (pkgs.system == "aarch64-darwin") ''
      extra-platforms = x86_64-darwin aarch64-darwin
    '';
  };

  # Required by home-manager.
  users.users.cjv.home = "/Users/cjv";

  environment.systemPackages = with pkgs; [
    # Emacs related
    nixfmt
    cmake
    ccls
    nodejs
    clang-tools
    graphviz
    black
    shellcheck
    shfmt
    nodePackages.js-beautify
    nodePackages.stylelint
    texlab
    # texlive.combined.scheme-full # Quite big, around 20GB. Remove if I'm running out of space.

    fzf
    hugo
    go
    neovim
    wget
    yt-dlp
    inputs.agenix.packages."${system}".default
  ];

  homebrew = {
    # STATE: requires manually installing Homebrew: brew.sh
    enable = true;
    onActivation = {
      autoUpdate = true;
      cleanup = "zap";
      upgrade = true;
    };

    brews = [
      "ollama"
      "python-tk"
      "rlwrap"
      "sbcl"
      "trash"

      # Doom Emacs dependencies
      "coreutils"
      "fd"
      "gcc"
      "git"
      "grep"
      "libgccjit"
      "marked"
      "ripgrep"
      "direnv"

      # pdf-tools dependencies
      "pkg-config"
      "autoconf"
      "automake"
      "poppler"
      # poppler dependencies
      "xorgproto"
      "libxau"
      "libxdmcp"
      "libxcb"
      "libx11"
      "libxext"
      "libxrender"
      "lzo"
      "pixman"
      "cairo"
      "xz"
      "nspr"
      "nss"

      # vterm dependencies
      "libtool"
      "libvterm"
    ];

    # Update these applicaitons manually.
    # As brew would update them by unninstalling and installing the newest
    # version, it could lead to data loss.
    casks = [
      "balenaetcher"
      "betterdisplay" # Custom fractional scaling resolutions, brightness and volume control for non-Apple external displays.
      "brave-browser"
      "discord"
      "docker"
      "emacs-mac"
      "firefox"
      "iterm2"
      "mattermost"
      # "microsoft-office" # Only have installed when needed (has some sinister telemetry).
      # "monitorcontrol" # Brightness and volume controls for external monitors.
      "mullvad-browser"
      "nextcloud"
      "orcaslicer"
      "orion"
      "qmk-toolbox"
      "signal"
      "stremio"
      "transmission"
      "ukelele"
      "unnaturalscrollwheels"
      "utm"
      "visual-studio-code"
      "whatsapp"
      "zoom"
    ];

    masApps = {
      AdGuard = 1440147259;
      Consent = 1606897889;
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
      "railwaycat/emacsmacport" # emacs-mac
    ];
  };

  programs = {
    man.enable = true;

    zsh = {
      # Create /etc/zshrc that loads the nix-darwin environment.
      enable = true;

      enableBashCompletion = true;
      enableCompletion = true;
      enableFzfCompletion = true;
      enableFzfHistory = true;
      enableSyntaxHighlighting = true;

      shellInit = ''
        # Make sure brew is on the path for M1.
        if [[ $(uname -m) == 'arm64' ]]; then
             eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
      '';
    };
  };

  environment.variables = { HOMEBREW_NO_ANALYTICS = "1"; };

  # Disable press and hold for diacritics.
  # I want to be able to press and hold j and k
  # in VSCode with vim keys to move around.
  system.defaults.NSGlobalDomain.ApplePressAndHoldEnabled = false;

  # Keyboard
  system.keyboard.enableKeyMapping = true;
  system.keyboard.remapCapsLockToControl = true;

  security.pam.enableSudoTouchIdAuth = true;

  home-manager.users.cjv = {
    programs.zsh.initExtra = ''
      # Enable iTerm2 shell integration.
      test -e "~/.iterm2_shell_integration.zsh" && source "~/.iterm2_shell_integration.zsh"
    '';

    home.stateVersion = "23.05";
  };

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;
}
