{ config, lib, pkgs, ... }:

{
  boot.kernelPackages = pkgs.linuxPackages_xanmod;

  services = {
    dbus.enable = true;

    gnome.gnome-keyring.enable = true;

    pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    printing.enable = true;

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
      "nngceckbapebfimnlniiiahkandclblb" # Bitwarden
      "fhnegjjodccfaliddboelcleikbmapik" # Chrome Tab Counter
      "gebbhagfogifgggkldgodflihgfeippi" # Return YouTube Dislike
    ];
  };

  environment.systemPackages = with pkgs; [
    brave
    discord
    firefox
    libreoffice-fresh
    librewolf
    mattermost-desktop
    monero-gui
    nextcloud-client
    nyxt
    ungoogled-chromium
    signal-desktop
    rnote
    spotify
    stremio
    xournalpp

    sbcl
    rlwrap
    python3

    # university, delete after they're not needed anymore
    jdk17
    maven
  ];
}
