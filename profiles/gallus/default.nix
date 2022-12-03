{ config, lib, pkgs, ... }:

{
  # TODO plymouth module
  boot = {
    plymouth.enable = true;
    initrd.systemd.enable = true;
  };

  powerManagement.powertop.enable = true;
  services = {
    power-profiles-daemon.enable = true;
    udev.extraRules = ''
      SUBSYSTEM=="power_supply",ENV{POWER_SUPPLY_ONLINE}=="0",RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced"
      SUBSYSTEM=="power_supply",ENV{POWER_SUPPLY_ONLINE}=="1",RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set performance"
    '';
  };

  # TODO migrar módulos cjv (para já, copiar só)
  boot.loader = {
    efi.canTouchEfiVariables = true;

    systemd-boot = {
      enable = true;
      editor = false;
      configurationLimit = 10;
    };
  };

  users.mutableUsers = true; # TODO hashed passwords

  time.timeZone = "Europe/Lisbon";
  documentation.man.generateCaches = true;

  programs = {
    neovim = {
      enable = true;
      viAlias = true;
      vimAlias = true;
      # defaultEditor = true;
    };

  };

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

  programs = {
    zsh = {
      enable = true;

      vteIntegration = true;
      enableBashCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;

      setOptions =
        [ "HIST_IGNORE_DUPS" "SHARE_HISTORY" "HIST_FCNTL_LOCK" "EMACS" ];

      shellInit = ''
        # Completion based on man pages
        zstyle ':completion:*:manuals'    separate-sections true
        zstyle ':completion:*:manuals.*'  insert-sections   true
        zstyle ':completion:*:man:*'      menu yes select

        # Delete words like bash
        autoload -U select-word-style
        select-word-style bash
      '';

      shellAliases = {
        update = "sudo nixos-rebuild switch --flake ~/Documents/Code/dotfiles";
        upgrade =
          "cd ~/Documents/Code/dotfiles && nix flake update && sudo nixos-rebuild boot --flake ~/Documents/Code/dotfiles";
      };
    };

    starship.enable = true;
  };

  environment.pathsToLink = [ "/share/zsh" ]; # For zsh completion
  users.defaultUserShell = pkgs.zsh;

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

  networking.hostId = "b60d3eae";
  networking.firewall.enable = false;

  programs.adb.enable = true;

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

    # Enable CUPS to print documents.
    printing = {
      enable = true;
      drivers = [
        pkgs.canon-cups-ufr2
        pkgs.cups-bjnp
        pkgs.gutenprint
        pkgs.gutenprintBin
      ];
    };

    # STATE: librewolf, stremio, rnote; GNOME Software faz auto-update
    # STATE: add flathub
    # flatpak.enable = true;

    # nextdns.enable = true; # TODO confirmar/apagar

    # Enable network scanning.
    avahi = {
      enable = true;
      nssmdns = true;
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

    # dnscrypt-proxy2 = {
    #   enable = true;
    #   settings = {
    #     ipv6_servers = true;
    #     require_dnssec = true;

    #     sources.public-resolvers = {
    #       urls = [
    #         "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
    #         "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
    #       ];
    #       cache_file = "/var/lib/dnscrypt-proxy2/public-resolvers.md";
    #       minisign_key =
    #         "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
    #     };

    #     # You can choose a specific set of servers from https://github.com/DNSCrypt/dnscrypt-resolvers/blob/master/v3/public-resolvers.md
    #     server_names = [ "cloudflare" ];
    #   };
    # };

    zfs = {
      trim.enable = true;
      autoScrub.enable = true;
      # autoSnapshot.enable = true;
    };

    fwupd.enable = true;

    resolved = {
      enable = true;
      extraConfig = ''
        DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
        Domains=~.
      '';
    };

    emacs = let
      myEmacs = pkgs.emacs-gtk.overrideAttrs (attrs: {
        # I don't want emacs.desktop file because I only use
        # emacsclient.
        postInstall = (attrs.postInstall or "") + ''
          rm $out/share/applications/emacs.desktop
        '';
      });
    in {
      enable = true;
      defaultEditor = true;
      package = ((pkgs.emacsPackagesFor myEmacs).emacsWithPackages
        (epkgs: [ epkgs.vterm epkgs.pdf-tools ]));
    };
  };

  hardware = {
    sane = {
      enable = true;
      extraBackends = [ pkgs.sane-airscan ];
    };
  };

  virtualisation = {
    libvirtd.enable = true;
    spiceUSBRedirection.enable = true;

    # virtualbox.host.enable = true;
    # waydroid.enable = true; # STATE: initial waydroid setup; check their website
  };
}
