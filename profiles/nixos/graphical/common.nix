{ self, config, lib, pkgs, ... }:

let
  # TODO automatically make every pkg in pkgs/ available everywhere
  # TODO use self instead of the ../..
  # brainworkshop = pkgs.callPackage ../../../pkgs/brainworkshop.nix { };
  orca-slicer = pkgs.callPackage ../../../pkgs/orca-slicer.nix { };
  qidi-slicer = pkgs.callPackage ../../../pkgs/qidi-slicer.nix { };
in {
  imports = [
    # "${self}/profiles/home/firefox.nix"
    # ../../home/firefox.nix
  ];

  # boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  # boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_xanmod_latest; # Lowest input lag, from my experienece.

  # Improve desktop responsiveness when updating the system.
  nix.daemonCPUSchedPolicy = "idle";

  # Pipewire
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  services = {
    dbus.enable = true;

    gnome.gnome-keyring.enable = true;

    xserver = {
      enable = true;

      layout = "us";
      xkbOptions = "ctrl:nocaps compose:prsc";
      xkbVariant = "altgr-intl";
      autoRepeatInterval = 30;
      autoRepeatDelay = 200;

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
  };

  programs.chromium = {
    enable = true;
    extensions = [
      # STATE: Bypass Paywalls Clean

      # STATE: Auto-fill > Default URI match detection > Host
      "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
      "fhnegjjodccfaliddboelcleikbmapik" # Chrome Tab Counter
      "mdjildafknihdffpkfmmpnpoiajfjnjd" # Consent-O-Matic
      "eimadpbcbfnmbkopoojfekhnkhdbieeh" # Dark Reader
      "dmhgdnbkjkejeddddlklojinngaideac" # Nudgeware
      "gebbhagfogifgggkldgodflihgfeippi" # Return YouTube Dislike
      "mnjggcdmjocbbbhaepdhchncahnbgone" # SponsorBlock
    ];
  };

  environment.systemPackages = with pkgs; [
    # brainworkshop

    # STATE:
    # - Set as default browser
    # - Hide brave rewards icon in search bar
    # - Hide brave wallet icon
    # - Password Manager > Settings > Disable offer to save passwords
    # - Homepage:
    #   - Disable cards
    #   - Disable sponsored background images
    #   - Disable Brave News
    #   - 24 hour clock
    # - Never translate Portuguese
    # - (Trajanus) Settings > 110% page zoom
    # - Vertical Tabs (keep expanded); disable expand vertical tabs panel on mouseover when collapsed
    # - Never show bookmarks bar
    # brave # TODO not available in aarch64, enable otherwise

    # STATE: Settings > Linux Settings > Disable Opening Discord at Startup and Minimizing to Tray
    (discord.override { withOpenASAR = true; })
    firefox
    libreoffice-fresh
    librewolf
    mattermost-desktop
    monero-gui

    # STATE:
    # - login, skip folders configuration, add folder connection ~/org -> Org
    # - launch on system startup, use monochrome icons
    # - move removed files to trash
    # - disable show server notifications (maybe, choose accordingly)
    nextcloud-client

    nyxt
    ungoogled-chromium
    orca-slicer
    qidi-slicer
    signal-desktop
    stremio
    thunderbird

    sbcl
    rlwrap
    python3
    yt-dlp
  ];

  home-manager.users.cjv = {
    dconf = {
      enable = true;
      settings = {
        "org/gnome/desktop/interface" = { color-scheme = "prefer-dark"; };
      };
    };

    gtk = {
      enable = true;

      theme = {
        # Use `dconf watch /` to see the correct name
        package = pkgs.adw-gtk3;
        name = "adw-gtk3-dark";
      };

      iconTheme = {
        package = pkgs.gnome.adwaita-icon-theme;
        name = "Adwaita";
      };
    };

    qt = {
      enable = true;
      platformTheme = "gnome";
      style = {
        name = "adwaita-dark";
        package = pkgs.adwaita-qt;
      };
    };
  };
}
