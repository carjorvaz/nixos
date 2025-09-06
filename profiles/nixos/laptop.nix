{ lib, pkgs, ... }:

{
  services = {
    dwm-status.settings.order = [
      "battery"
      "time"
    ];

    # Thermald and TLP might be more harmful than good, leave disabled
    # https://pointieststick.com/2020/06/08/lenovo-thinkpad-x1-yoga-impressions-bugs-workarounds-and-thoughts-about-the-future/#comment-10995
    power-profiles-daemon.enable = true;
    thermald.enable = false;
    tlp.enable = false;
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
  };
}
