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
    "${self}/profiles/darwin/fish.nix"
    "${self}/profiles/home/helix.nix"
    "${self}/profiles/home/ssh.nix"
  ];

  nix = {
    enable = true;

    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };

    registry = {
      nixpkgs.flake = inputs.nixpkgs-darwin;
      unstable.flake = inputs.nixpkgs-unstable;
    };

    extraOptions = lib.optionalString (pkgs.system == "aarch64-darwin") ''
      extra-platforms = x86_64-darwin aarch64-darwin
    '';
  };

  networking.hostName = "mac";

  environment.systemPackages = with pkgs; [
    colima # Streamlines Docker, just run `colima start`.
    docker
    htop
    llama-cpp
    nixos-rebuild

    delta
    dua
    fd
    hyperfine
    ripgrep
    ripgrep-all
    uutils-coreutils-noprefix

    # Emacs related
    nixfmt-rfc-style
    cmake
    ccls
    nodejs
    clang-tools
    graphviz
    black
    shellcheck
    shfmt
    nil # nix LSP
    nodePackages.js-beautify
    nodePackages.stylelint
    pyright
    python3Packages.pygments
    rust-analyzer
    texlab
    texlive.combined.scheme-full # Quite big, around 20GB. Remove if I'm running out of space.

    # brainworkshop dependencies
    # STATE: venv with pyglet installed with direnv
    ffmpeg

    delta
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
    # If not installed, nix-darwin will instruct on how to install
    enable = true;

    onActivation = {
      autoUpdate = true;
      cleanup = "zap";
      upgrade = true;
    };

    brews = [
      "julia"
      "pipx"
      "python-tk"
      "rlwrap"
      "sbcl"
      "trash"

      "qmk"
      # QMK dependencies
      "avr-binutils"
      "avr-gcc@8"
      "boost"
      "confuse"
      "hidapi"
      "libftdi"
      "libusb-compat"
      "avrdude"
      "bootloadhid"
      "clang-format"
      "dfu-programmer"
      "dfu-util"
      "libimagequant"
      "libraqm"
      "pillow"
      "teensy_loader_cli"
      "osx-cross/arm/arm-none-eabi-binutils"
      "osx-cross/arm/arm-none-eabi-gcc@8"
      "osx-cross/avr/avr-gcc@9"
      "qmk/qmk/hid_bootloader_cli"
      "qmk/qmk/mdloader"

      {
        # Emacs
        # STATE: ln -s /usr/local/opt/emacs-plus/Emacs.app /Applications/Emacs.app
        name = "emacs-plus@30";
        args = [
          "with-native-comp"
          "with-c9rgreen-sonoma-icon"
        ];
      }
      # Emacs dependencies
      "awk"
      "fribidi"
      "gdk-pixbuf"
      "giflib"
      "gnu-sed"
      "gnu-tar"
      "graphite2"
      "harfbuzz"
      "jansson"
      "jpeg"
      "pango"
      "librsvg"
      "make"
      "texinfo"
      "tree-sitter"
      "webp"
      "zlib"
      # Doom Emacs dependencies
      "coreutils"
      "gcc"
      "git"
      "grep"
      "libgccjit"
      "marked"
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

    # Update these applicatons manually.
    # As brew would update them by unninstalling and installing the newest
    # version, it could lead to data loss.
    casks = [
      "balenaetcher"
      "betterdisplay" # Custom fractional scaling resolutions, brightness and volume control for non-Apple external displays.
      "brave-browser"
      "citrix-workspace"
      "discord"
      "firefox"
      "flux"
      "font-jetbrains-mono-nerd-font"
      "ghostty"
      "iina"
      "inkscape"
      "karabiner-elements" # STATE: Rebind right-command to right-option
      "mattermost"
      # "microsoft-office" # Only have installed when needed (has some sinister telemetry).
      "microsoft-teams" # Only have installed when needed (has some sinister telemetry).
      # "monitorcontrol" # Brightness and volume controls for external monitors.
      "mullvad-browser"
      "nextcloud"
      "orcaslicer"
      "orion"
      "qmk-toolbox"
      "racket"
      "signal"
      "stremio"
      "telegram"
      "transmission"
      "tunnelblick"
      "ukelele"
      "unnaturalscrollwheels"
      "utm"
      "vial"
      "visual-studio-code"
      "whatsapp"
      "zed"
      "zoom"
    ];

    masApps = {
      AdGuard = 1440147259;
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
      "d12frosted/emacs-plus"
      "osx-cross/arm"
      "osx-cross/avr"
      "qmk/qmk"
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

  # Keyboard
  system.keyboard.enableKeyMapping = true;
  system.keyboard.remapCapsLockToControl = true;

  security.pam.services.sudo_local.touchIdAuth = true;

  # Required by home-manager.
  users.users.cjv.home = "/Users/cjv";

  home-manager.users.cjv = {
    home.stateVersion = "23.05";
  };

  ids.gids.nixbld = 350;
  system.primaryUser = "cjv";

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;
}
