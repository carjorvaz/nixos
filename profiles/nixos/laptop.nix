{ config, lib, pkgs, ... }:

{
  boot = {
    # For battery thresholds.
    kernelModules = [ "acpi_call" ];
    extraModulePackages = with config.boot.kernelPackages; [ acpi_call ];
  };

  services.power-profiles-daemon.enable = true;

  # Only use this once per ThinkPad, then return to power-profiles-daemon
  # services.tlp = {
  #   enable = true;
  #   settings = {
  #     # Extend battery longevity.
  #     START_CHARGE_THRESH_BAT0 = 75;
  #     STOP_CHARGE_THRESH_BAT0 = 80;
  #   };
  # };

  home-manager.users.cjv.wayland.windowManager.hyprland.settings = {
    # https://wiki.hyprland.org/FAQ/#how-heavy-is-this
    # I prefer no animations so it feels snappier.
    animations.enabled = false;

    decoration = {
      # https://wiki.hyprland.org/FAQ/#how-do-i-make-hyprland-draw-as-little-power-as-possible-on-my-laptop
      blur.enabled = false;
      drop_shadow = false;
    };

    misc.vfr = true;
  };
}
