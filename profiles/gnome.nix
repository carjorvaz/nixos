{ config, lib, pkgs, ... }:

{
  services.xserver = {
    enable = true;

    desktopManager.gnome.enable = true;
    displayManager.gdm = {
      enable = true;
      wayland = true;
      autoSuspend = false;
    };

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
