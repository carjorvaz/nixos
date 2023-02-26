{ config, lib, pkgs, ... }:

{
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
    brave
    discord
    firefox
    libreoffice-fresh
    librewolf
    mattermost-desktop
    monero-gui
    nextcloud-client
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
