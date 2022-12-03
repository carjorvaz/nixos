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
    unstable.brave
    unstable.discord
    unstable.mattermost-desktop
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
    python-with-my-packages
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
    unstable.rnote
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

      setOptions = [
        "HIST_IGNORE_DUPS"
        "SHARE_HISTORY"
        "HIST_FCNTL_LOCK"
        "EMACS"

      ];

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

  networking.wg-quick.interfaces.wgrnl = let wgrnlFwmark = "765";
  in {
    address = [ "192.168.20.32/24" "fd92:3315:9e43:c490::32/64" ];
    privateKeyFile = /persist/secrets/wireguard/privatekey;
    table = wgrnlFwmark;
    postUp = ''
      ${pkgs.wireguard-tools}/bin/wg set wgrnl fwmark ${wgrnlFwmark}
      ${pkgs.iproute2}/bin/ip rule add not fwmark ${wgrnlFwmark} table ${wgrnlFwmark}
      ${pkgs.iproute2}/bin/ip -6 rule add not fwmark ${wgrnlFwmark} table ${wgrnlFwmark}

      # multicast
      ${pkgs.iproute2}/bin/ip link set wgrnl multicast on

      # systemd-resolved
      # Adiciona como domínios desta interface todos os domínios (~.).
      # Para o caso de aparecerem outras interfaces com maior prioridade, adiciona também todos os domínios da RNL, e todos os domínios de rDNS para gamas da RNL (públicas, privadas e watergate no INESC). Todos os domínios excepto rnl.tecnico.ulisboa.pt começam com ~ para desligar dns-search neles.
      ${pkgs.systemd}/bin/resolvectl dns wgrnl 193.136.164.1 2001:690:2100:80::1 193.136.164.2 2001:690:2100:80::2
      ${pkgs.systemd}/bin/resolvectl domain wgrnl ~. rnl.tecnico.ulisboa.pt ~rnl.ist.utl.pt ~rnl.pt ~164.136.193.in-addr.arpa ~154.136.193.in-addr.arpa ~8.0.0.0.0.1.2.0.9.6.0.1.0.0.2.ip6.arpa ~81.33.193.146.in-addr.arpa ~20.168.192.in-addr.arpa ~0.9.4.c.3.4.e.9.5.1.3.3.2.9.d.f.ip6.arpa ~154.168.192.in-addr.arpa ~64.16.10.in-addr.arpa ~65.16.10.in-addr.arpa ~66.16.10.in-addr.arpa ~67.16.10.in-addr.arpa ~68.16.10.in-addr.arpa ~69.16.10.in-addr.arpa ~70.16.10.in-addr.arpa ~71.16.10.in-addr.arpa ~72.16.10.in-addr.arpa ~73.16.10.in-addr.arpa ~74.16.10.in-addr.arpa ~75.16.10.in-addr.arpa ~76.16.10.in-addr.arpa ~77.16.10.in-addr.arpa ~78.16.10.in-addr.arpa ~79.16.10.in-addr.arpa ~80.16.10.in-addr.arpa ~81.16.10.in-addr.arpa ~82.16.10.in-addr.arpa ~83.16.10.in-addr.arpa ~84.16.10.in-addr.arpa ~85.16.10.in-addr.arpa ~86.16.10.in-addr.arpa ~87.16.10.in-addr.arpa ~88.16.10.in-addr.arpa ~89.16.10.in-addr.arpa ~90.16.10.in-addr.arpa ~91.16.10.in-addr.arpa ~92.16.10.in-addr.arpa ~93.16.10.in-addr.arpa ~94.16.10.in-addr.arpa ~95.16.10.in-addr.arpa ~96.16.10.in-addr.arpa ~97.16.10.in-addr.arpa ~98.16.10.in-addr.arpa ~99.16.10.in-addr.arpa ~100.16.10.in-addr.arpa ~101.16.10.in-addr.arpa ~102.16.10.in-addr.arpa ~103.16.10.in-addr.arpa ~104.16.10.in-addr.arpa ~105.16.10.in-addr.arpa ~106.16.10.in-addr.arpa ~107.16.10.in-addr.arpa ~108.16.10.in-addr.arpa ~109.16.10.in-addr.arpa ~110.16.10.in-addr.arpa ~111.16.10.in-addr.arpa ~112.16.10.in-addr.arpa ~113.16.10.in-addr.arpa ~114.16.10.in-addr.arpa ~115.16.10.in-addr.arpa ~116.16.10.in-addr.arpa ~117.16.10.in-addr.arpa ~118.16.10.in-addr.arpa ~119.16.10.in-addr.arpa ~120.16.10.in-addr.arpa ~121.16.10.in-addr.arpa ~122.16.10.in-addr.arpa ~123.16.10.in-addr.arpa ~124.16.10.in-addr.arpa ~125.16.10.in-addr.arpa ~126.16.10.in-addr.arpa ~127.16.10.in-addr.arpa
    '';

    preDown = ''
      ${pkgs.iproute2}/bin/ip rule del not fwmark ${wgrnlFwmark} table ${wgrnlFwmark}
      ${pkgs.iproute2}/bin/ip -6 rule del not fwmark ${wgrnlFwmark} table ${wgrnlFwmark}
    '';

    peers = [{
      publicKey = "g08PXxMmzC6HA+Jxd+hJU0zJdI6BaQJZMgUrv2FdLBY=";
      # endpoint = "hagrid.rnl.tecnico.ulisboa.pt:34266";
      endpoint = "193.136.164.211:34266";
      persistentKeepalive = 25;
      allowedIPs = [
        # gamas públicas da RNL
        "193.136.164.0/24"
        "193.136.154.0/24"
        "2001:690:2100:80::/58"

        # gamas privadas da RNL
        "10.16.64.0/18" # routed dentro do IST
        "192.168.20.0/24" # VPN IPv4
        "fd92:3315:9e43:c490::/64" # VPN IPv6
        "192.168.154.0/24" # Labs AMT

        # gama uplink Zeus (DSI+RNL)
        "193.136.128.24/29"

        # watergate (INESC)
        "146.193.33.81/32"

        # multicast e mDNS
        "224.0.0.0/24"
        "ff02::/16"
        "239.255.255.250/32"
        "239.255.255.253/32"
        "fe80::/10"
      ];
    }];
  };

  networking.hostId = "b60d3eae";
  networking.firewall.enable = false;

  i18n = {
    defaultLocale = "en_US.utf8";
    extraLocaleSettings = {
      LC_ADDRESS = "pt_PT.utf8";
      LC_IDENTIFICATION = "pt_PT.utf8";
      LC_MEASUREMENT = "pt_PT.utf8";
      LC_MONETARY = "pt_PT.utf8";
      LC_NAME = "pt_PT.utf8";
      LC_NUMERIC = "pt_PT.utf8";
      LC_PAPER = "pt_PT.utf8";
      LC_TELEPHONE = "pt_PT.utf8";
      LC_TIME = "pt_PT.utf8";
    };
  };

  programs.adb.enable = true;

  networking.wireless.iwd.enable = true;
  networking.networkmanager.wifi.backend = "iwd";


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

  # Enable PipeWire.
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;
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
