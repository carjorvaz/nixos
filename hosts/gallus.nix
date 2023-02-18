{ config, pkgs, lib, suites, ... }:

{
  imports = suites.gallus;

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "nvme" "usb_storage" "sd_mod" ];
  boot.kernelModules = [ "kvm-intel" "acpi_call" ];
  boot.kernelPackages =
    lib.mkDefault config.boot.zfs.package.latestCompatibleLinuxPackages;
  boot.extraModulePackages = with config.boot.kernelPackages; [ acpi_call ];

  boot.supportedFilesystems = [ "zfs" ];
  networking.hostId = "b60d3eae";

  fileSystems."/" = {
    device = "zroot/local/root";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/23BD-94D0";
    fsType = "vfat";
  };

  fileSystems."/nix" = {
    device = "zroot/local/nix";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/home" = {
    device = "zroot/safe/home";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/persist" = {
    device = "zroot/safe/persist";
    fsType = "zfs";
    options = [ "zfsutil" ];
    neededForBoot = true;
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    sensor.iio.enable = true;
  };

  networking.useDHCP = lib.mkDefault true;
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  hardware.video.hidpi.enable = lib.mkDefault true;

  powerManagement.powertop.enable = true;
  environment.systemPackages = with pkgs; [ powertop ];

  services = {
    kanata.keyboards."colemak".devices =
      [ "/dev/input/by-path/platform-i8042-serio-0-event-kbd" ];

    xserver.wacom.enable = true;
    udev.extraRules = ''
      # blacklist Lenovo IR camera
      SUBSYSTEM=="usb", ATTRS{idVendor}=="5986", ATTRS{idProduct}=="211a", ATTR{authorized}="0"
    '';

    thermald.enable = false;
    throttled = {
      enable = true;
      extraConfig = ''
        [GENERAL]
        # Enable or disable the script execution
        Enabled: True
        # SYSFS path for checking if the system is running on AC power
        Sysfs_Power_Path: /sys/class/power_supply/AC*/online
        # Auto reload config on changes
        Autoreload: True

        ## Settings to apply while connected to Battery power
        [BATTERY]
        # Update the registers every this many seconds
        Update_Rate_s: 30
        # Max package power for time window #1
        PL1_Tdp_W: 29
        # Time window #1 duration
        PL1_Duration_s: 28
        # Max package power for time window #2
        PL2_Tdp_W: 44
        # Time window #2 duration
        PL2_Duration_S: 0.002
        # Max allowed temperature before throttling
        Trip_Temp_C: 85
        # Set cTDP to normal=0, down=1 or up=2 (EXPERIMENTAL)
        cTDP: 0
        # Disable BDPROCHOT (EXPERIMENTAL)
        Disable_BDPROCHOT: False

        ## Settings to apply while connected to AC power
        [AC]
        # Update the registers every this many seconds
        Update_Rate_s: 5
        # Max package power for time window #1
        PL1_Tdp_W: 44
        # Time window #1 duration
        PL1_Duration_s: 28
        # Max package power for time window #2
        PL2_Tdp_W: 44
        # Time window #2 duration
        PL2_Duration_S: 0.002
        # Max allowed temperature before throttling
        Trip_Temp_C: 95
        # Set HWP energy performance hints to 'performance' on high load (EXPERIMENTAL)
        # Uncomment only if you really want to use it
        # HWP_Mode: False
        # Set cTDP to normal=0, down=1 or up=2 (EXPERIMENTAL)
        cTDP: 0
        # Disable BDPROCHOT (EXPERIMENTAL)
        Disable_BDPROCHOT: False


        [UNDERVOLT]
        # CPU core voltage offset (mV)
        CORE: -105
        # Integrated GPU voltage offset (mV)
        GPU: -85
        # CPU cache voltage offset (mV)
        CACHE: -105
        # System Agent voltage offset (mV)
        UNCORE: -85
        # Analog I/O voltage offset (mV)
        ANALOGIO: 0
      '';

    };

    # Refrain from using the power saver profile.
    power-profiles-daemon.enable = true;
  };

  services.wgrnl = {
    enable = true;
    privateKeyFile = "/persist/secrets/wireguard/privatekey"; # TODO agenix
  };

  home-manager.users.cjv = {
    # TODO:
    # - on-screen keyboard
    # - screen rotation
    programs.i3status-rust.bars.top = {
      settings.scrolling = "natural";
      blocks = [
        {
          block = "net";
          format = " {ssid}";
        }
        {
          block = "backlight";
          invert_icons = true;
          cycle = [ 100 50 0 50 ];
          format = "{brightness}";
        }
        {
          block = "sound";
          max_vol = 100;
          headphones_indicator = true;
          device_kind = "sink";
        }
        {
          block = "sound";
          max_vol = 100;
          device_kind = "source";
        }
        {
          block = "battery";
          interval = 10;
          format = " {percentage} - {time} remaining ({power})";
          full_format = " Fully charged";
        }
        {
          block = "time";
          interval = 5;
          format = "%a %d/%m %R";
        }
      ];
    };

    wayland.windowManager.sway.config.output."*".bg =
      "~/Pictures/bierstadt.jpg fill";
  };

  system.stateVersion = "22.05";
}
