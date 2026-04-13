{ lib, pkgs, ... }:

{
  # Battery notifications via UPower D-Bus, without polling.
  systemd.user.services.batsignal = {
    description = "Battery level notification daemon";
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.batsignal}/bin/batsignal -w 20 -c 15 -d 10 -D '${pkgs.systemd}/bin/systemctl suspend'";
      Restart = "on-failure";
    };
  };

  services = {
    dwm-status.settings.order = [
      "battery"
      "time"
    ];

    # Thermald is Intel-only, not useful for AMD
    thermald.enable = false;

    # TLP handles AC/battery switching for all power-related knobs.
    # scx_lavd --autopower polls the EPP value TLP sets, so the scheduler
    # automatically follows the power profile (performance ↔ powersave).
    #
    # Previous approach: PPD + udev rules
    # https://pointieststick.com/2020/06/08/lenovo-thinkpad-x1-yoga-impressions-bugs-workarounds-and-thoughts-about-the-future/#comment-10995
    # https://community.frame.work/t/responded-amd-7040-sleep-states/38101/13
    power-profiles-daemon.enable = false;

    tlp = {
      enable = true;
      settings = {
        # -- CPU --
        # amd-pstate-epp handles governor internally, just set EPP
        CPU_ENERGY_PERF_POLICY_ON_AC = "performance";
        CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
        CPU_BOOST_ON_AC = 1;
        CPU_BOOST_ON_BAT = 0;
        CPU_HWP_DYN_BOOST_ON_AC = 1;
        CPU_HWP_DYN_BOOST_ON_BAT = 0;

        # -- Runtime PM (PCI devices) --
        RUNTIME_PM_ON_AC = "on";
        RUNTIME_PM_ON_BAT = "auto";

        # -- PCIe ASPM --
        PCIE_ASPM_ON_AC = "performance";
        PCIE_ASPM_ON_BAT = "powersupersave";

        # -- USB --
        USB_AUTOSUSPEND = 1;
        USB_EXCLUDE_PHONE = 1;

        # -- Audio --
        SOUND_POWER_SAVE_ON_AC = 0;
        SOUND_POWER_SAVE_ON_BAT = 1;

        # -- WiFi --
        WIFI_PWR_ON_AC = "off";
        WIFI_PWR_ON_BAT = "on";

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
