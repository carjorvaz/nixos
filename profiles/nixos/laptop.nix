{
  config,
  lib,
  pkgs,
  ...
}:

{
  services = {
    dwm-status.order = [
      "battery"
      "time"
    ];

    tlp.enable = true;
  };

  home-manager.users.cjv = {
    programs.i3status-rust.bars.top.blocks = lib.mkForce [
      {
        block = "battery";
        format = " $icon $percentage ($power) ($time remaining) ";
      }
      {
        block = "sound";
        max_vol = 100;
        headphones_indicator = true;
        device_kind = "sink";
        click = [
          {
            button = "left";
            cmd = "${pkgs.rofi-pulse-select}/bin/rofi-pulse-select sink";
          }
        ];
      }
      {
        block = "sound";
        max_vol = 100;
        device_kind = "source";
        click = [
          {
            button = "left";
            cmd = "${pkgs.rofi-pulse-select}/bin/rofi-pulse-select source";
          }
        ];
      }
      {
        block = "time";
        interval = 5;
        format = " $timestamp.datetime(f:'%a %d/%m %R')";
      }
    ];

    wayland.windowManager.hyprland.settings = {
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
  };
}
