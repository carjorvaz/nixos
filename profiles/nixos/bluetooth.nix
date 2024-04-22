{ config, lib, pkgs, ... }:

let
  isWindowManager =
    if config.programs.sway.enable || config.programs.hyprland.enable then
      true
    else
      false;
in {
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  services.blueman.enable = isWindowManager;

  home-manager.users.cjv.services.blueman-applet.enable = isWindowManager;
}
