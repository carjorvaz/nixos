{ config, lib, pkgs, ... }:

{
  powerManagement.powertop.enable = true;
  services = {
    power-profiles-daemon.enable = true;
    udev.extraRules = ''
      SUBSYSTEM=="power_supply",ENV{POWER_SUPPLY_ONLINE}=="0",RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced"
      SUBSYSTEM=="power_supply",ENV{POWER_SUPPLY_ONLINE}=="1",RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set performance"
    '';
  };

  users.mutableUsers = true; # TODO hashed passwords
  documentation.man.generateCaches = true;

  environment.systemPackages = with pkgs; [
    wget
    unzip
    git
    man-pages
    man-pages-posix
    ripgrep
    fd
    neovim
    htop
    pstree
    trash-cli
    whois
    neofetch
    html-tidy
    brave
    discord
    mattermost-desktop
    ripgrep
    sqlite # Needed for org-roam.
    cmake
    gnumake
    sbcl
    lispPackages.quicklisp
    pandoc
    nixfmt
    graphviz
    shellcheck
    gcc
    clang-tools
    yt-dlp
    celluloid
    ungoogled-chromium
    spotify
    nextcloud-client
    trash-cli
    metadata-cleaner
    librewolf
    firefox # For account containers
    stremio
    monero-gui
    virt-manager
    spice-gtk # needed for usb redirection in vms
    appimage-run
    signal-desktop
    bashmount
    bitwarden
    steam-run-native
    zeal
    kiwix
    gnome.gnome-tweaks
    fragments
    drawing
    foliate
    pdfslicer
    black
    nodePackages.pyright
    python310Packages.pygments # needed for code syntax highlighting in LaTeX
    gnome.gnome-sound-recorder
    yarn
    nodePackages.gulp
    binutils
    coreutils
    # ((emacsPackagesFor emacs).emacsWithPackages
    #   (epkgs: [ epkgs.emacsql-sqlite epkgs.pdf-tools epkgs.vterm ]))
    libtool
    gnutls
    imagemagick
    zstd
    (aspellWithDicts (ds: with ds; [ en en-computers en-science pt_PT ]))
    texlive.combined.scheme-full
    texlab
    ansible
    wl-clipboard
    nodePackages.stylelint
    nodePackages.js-beautify
    qalculate-gtk
    nodejs
    hugo
    go
    krb5
    libreoffice-fresh
    inkscape
    hyperfine
    bc
    languagetool
    nodePackages.javascript-typescript-langserver
    aspell
    aspellDicts.pt_PT
    aspellDicts.en
    aspellDicts.en-science
    aspellDicts.en-computers
    hunspell
    rnote
    xournalpp
    powertop
    waypipe
    magic-wormhole
    # # TODO home manager
    # (vscode-with-extensions.override {
    #   vscode = vscodium;
    #   vscodeExtensions = with vscode-extensions; [
    #     asvetliakov.vscode-neovim
    #     ms-toolsai.jupyter
    #     ms-toolsai.jupyter-renderers
    #     ms-python.python
    #   ];
    #   #   bbenoist.nix
    #   #   ms-azuretools.vscode-docker
    #   #   ms-vscode-remote.remote-ssh
    #   # ] ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [{
    #   #   name = "remote-ssh-edit";
    #   #   publisher = "ms-vscode-remote";
    #   #   version = "0.47.2";
    #   #   sha256 = "1hp6gjh4xp2m1xlm1jsdzxw9d8frkiidhph6nvl24d0h8z34w49g";
    #   # }];
    # })
    adw-gtk3
    blackbox-terminal
  ];

  # home-manager.users.root.programs = {
  #   zsh.enable = true;
  #   fzf.enable = true;
  # };

  # home-manager.users.cjv = mkIf config.cjv.user.enable {
  #   programs = {
  #     zsh = {
  #       enable = true;
  #       enableAutosuggestions = true;
  #       enableCompletion = true;
  #       enableSyntaxHighlighting = true;
  #       enableVteIntegration = true;
  #       autocd = true;
  #       defaultKeymap = "emacs";

  #       history = {
  #         expireDuplicatesFirst = true;
  #         extended = true;
  #         ignoreDups = true;
  #       };
  #     };

  #     fzf.enable = true;
  #   };
  # };

  # TODO distributed builds

  networking.firewall.enable = false;

  services = {
    xserver = {
      enable = true;

      displayManager.gdm.enable = true;
      desktopManager.gnome.enable = true;

      layout = "us";
      xkbOptions = "ctrl:nocaps compose:prsc";
      xkbVariant = "altgr-intl";

      libinput = {
        enable = true;

        # Disable mouse acceleration.
        mouse.accelProfile = "flat";

        touchpad = {
          disableWhileTyping = true;
          naturalScrolling = true;
        };
      };
    };


    openssh = {
      enable = true;
      passwordAuthentication = false;
      kbdInteractiveAuthentication = false;
    };

    # nebula.networks."Rome" = {
    #   enable = true;
    #   ca = "/persist/nebula/ca.crt";
    #   cert = "/persist/nebula/trajan.crt";
    #   key = "/persist/nebula/trajan.key";
    #   lighthouses = [ "192.168.100.1" ];
    #   staticHostMap = { "192.168.100.1" = [ "185.194.217.74:4242" ]; };
    #   firewall = {
    #     inbound = [{
    #       port = "any";
    #       proto = "any";
    #       host = "any";
    #     }];

    #     outbound = [{
    #       port = "any";
    #       proto = "any";
    #       host = "any";
    #     }];
    #   };
    # };

    zfs = {
      trim.enable = true;
      autoScrub.enable = true;
      # autoSnapshot.enable = true;
    };

    fwupd.enable = true;

  };

}
