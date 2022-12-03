{ config, lib, pkgs, ... }:

{
  services.xserver = {
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
}
