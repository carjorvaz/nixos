{ config, lib, pkgs, ... }:

{
  boot = {
    # For battery thresholds.
    kernelModules = [ "acpi_call" ];
    extraModulePackages = with config.boot.kernelPackages; [ acpi_call ];
  };

  # services.power-profiles-daemon.enable = true;

  # Only use this once per ThinkPad, then return to power-profiles-daemon TODO always use tlp
  services.tlp = {
    enable = true;
    settings = {
      # Extend battery longevity.
      START_CHARGE_THRESH_BAT0 = 75;
      STOP_CHARGE_THRESH_BAT0 = 80;
    };
  };

  home-manager.users.cjv = {
    programs.i3status-rust.bars.top.blocks = [
      { block = "battery"; }
      {
        block = "sound";
        max_vol = 100;
        headphones_indicator = true;
        device_kind = "sink";
        click = [{
          button = "left";
          cmd = "${pkgs.rofi-pulse-select}/bin/rofi-pulse-select sink";
        }];
      }
      {
        block = "sound";
        max_vol = 100;
        device_kind = "source";
        click = [{
          button = "left";
          cmd = "${pkgs.rofi-pulse-select}/bin/rofi-pulse-select source";
        }];
      }
      {
        block = "time";
        interval = 5;
        format = " $timestamp.datetime(f:'%a %d/%m %R')";
      }

    ];

    services.kanshi = {
      enable = true;

      profiles = {

        # Configuration file
        # Each output profile is delimited by brackets.
        # It contains several output directives (whose syntax is similar to sway-output(5)).
        # A profile will be enabled if all of the listed outputs are connected.
        # (wdisplays is useful to get the description criteria)

        # profile {
        # 	output LVDS-1 disable
        # 	output "Some Company ASDF 4242" mode 1600x900 position 0,0
        # }

        # profile {
        # 	output LVDS-1 enable scale 2
        # }

        undocked = {
          outputs = [{
            criteria = "eDP-1";
            scale = 1.0;
            status = "enable";
          }];
        };

        rnl = {
          outputs = [
            {
              criteria = "Iiyama North America PL3293UH 1213432400052";
              position = "0,0";
              scale = 1.25;
            }
            {
              criteria = "eDP-1";
              status = "disable";
            }
          ];
        };

        home = {
          outputs = [
            {
              criteria = "Dell Inc. DELL U3419W HW796T2";
              position = "0,0";
              scale = 1.0;
            }
            {
              criteria = "eDP-1";
              status = "disable";
            }
          ];

        };
      };
    };

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
