{ config, pkgs, lib, suites, ... }:

{
  imports = suites.laptop;

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "nvme" "usb_storage" "sd_mod" ];
  boot.kernelModules = [ "kvm-intel" "acpi_call"];
  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  boot.extraModulePackages = with config.boot.kernelPackages; [ acpi_call ];

  boot.supportedFilesystems = [ "zfs" ];
  networking.hostId = "b60d3eae";

  fileSystems."/" = {
    device = "zroot/local/root";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/23BD-94D0";
    fsType = "vfat";
  };

  fileSystems."/nix" = {
    device = "zroot/local/nix";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/home" = {
    device = "zroot/safe/home";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/persist" = {
    device = "zroot/safe/persist";
    fsType = "zfs";
    options = [ "zfsutil" ];
    neededForBoot = true;
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    sensor.iio.enable = true;
  };

  networking.useDHCP = lib.mkDefault true;
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  hardware.video.hidpi.enable = lib.mkDefault true;

  # TODO intel hardware acceleration profile module
  boot.initrd.kernelModules = [ "i915" ];
  environment.variables.VDPAU_DRIVER = "va_gl";
  hardware.opengl = {
    enable = true;
    extraPackages = with pkgs; [ vaapiIntel libvdpau-va-gl intel-media-driver ];
  };

  services = {
    throttled.enable = true;
    xserver.wacom.enable = true;
    udev.extraRules = ''
      # blacklist Lenovo IR camera
      SUBSYSTEM=="usb", ATTRS{idVendor}=="5986", ATTRS{idProduct}=="211a", ATTR{authorized}="0"
    '';
  };

  systemd.services.activate-touch-hack = {
    description = "Touch wake Thinkpad X1 Yoga 3rd gen hack";
    wantedBy = [
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend-then-hibernate.target"
    ];
    after = [
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend-then-hibernate.target"
    ];
    serviceConfig = {
      ExecStart = ''
        /bin/sh -c "echo '\\_SB.PCI0.LPCB.EC._Q2A'  > /proc/acpi/call"
      '';
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


  system.stateVersion = "22.05";
}
