{ config, lib, pkgs, ... }:

{
  boot = {
    # For battery thresholds.
    kernelModules = [ "acpi_call" ];
    extraModulePackages = with config.boot.kernelPackages; [ acpi_call ];
  };

  services.tlp = {
    enable = true;
    settings = {
      # Extend battery longevity.
      START_CHARGE_THRESH_BAT0 = 75;
      STOP_CHARGE_THRESH_BAT0 = 80;

      # https://linrunner.de/tlp/support/optimizing.html
      # https://linrunner.de/tlp/faq/ppd.html#how-can-i-use-tlp-to-achieve-the-same-effect-as-power-profiles-daemon
      PLATFORM_PROFILE_ON_AC = "balanced";
      PLATFORM_PROFILE_ON_BAT = "balanced";

      CPU_ENERGY_PERF_POLICY_ON_AC = "balance_performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "balance_power";

      CPU_BOOST_ON_AC = "1";
      CPU_BOOST_ON_BAT = "0";

      CPU_HWP_DYN_BOOST_ON_AC = "1";
      CPU_HWP_DYN_BOOST_ON_BAT = "0";
    };
  };

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
