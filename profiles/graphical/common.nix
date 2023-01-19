{ config, lib, pkgs, ... }:

{
  boot.kernelPackages = pkgs.linuxPackages_zen;

  services = {
    xserver = {
      enable = true;

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

    printing.enable = true;
  };

  environment.systemPackages = with pkgs; [
    celluloid
    drawing
    foliate
    fragments
    gnome.gnome-sound-recorder
    gnome.gnome-tweaks
    inkscape
    libreoffice-fresh
    metadata-cleaner
    pdfslicer
    qalculate-gtk
    rnote
    waypipe
    wl-clipboard
    xournalpp

    brave
    discord
    firefox
    librewolf
    mattermost-desktop
    monero-gui
    nextcloud-client
    ungoogled-chromium
    signal-desktop
    spotify
    stremio
  ];
}
