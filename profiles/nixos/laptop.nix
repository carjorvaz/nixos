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

    tlp = {
      enable = true;
      settings = {
        # https://wiki.hyprland.org/Configuring/Performance/#low-fpsstutterfps-drops-on-intel-igpu-with-tlp-mainly-laptops
        INTEL_GPU_MIN_FREQ_ON_AC = 500;
        INTEL_GPU_MIN_FREQ_ON_BAT = 500;
      };
    };
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
