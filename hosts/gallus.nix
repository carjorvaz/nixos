{ config, pkgs, lib, suites, ... }:

{
  imports = suites.gallus;

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "nvme" "usb_storage" "sd_mod" ];
  boot.kernelModules = [ "kvm-intel" "acpi_call" ];
  boot.kernelPackages = pkgs.linuxPackages_zen;
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

  boot.initrd.kernelModules = [ "i915" ];
  environment.variables.VDPAU_DRIVER = "va_gl";
  hardware.opengl = {
    enable = true;
    extraPackages = with pkgs; [ vaapiIntel libvdpau-va-gl intel-media-driver ];
  };


  powerManagement.powertop.enable = true;
  environment.systemPackages = with pkgs; [ powertop ];

  services = {
    xserver.wacom.enable = true;
    udev.extraRules = ''
      # blacklist Lenovo IR camera
      SUBSYSTEM=="usb", ATTRS{idVendor}=="5986", ATTRS{idProduct}=="211a", ATTR{authorized}="0"
    '';

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

        # All voltage values are expressed in mV and *MUST* be negative (i.e. undervolt)!
        [UNDERVOLT]
        # CPU core voltage offset (mV)
        CORE: -80
        # Integrated GPU voltage offset (mV)
        GPU: -80
        # CPU cache voltage offset (mV)
        CACHE: -80
        # System Agent voltage offset (mV)
        UNCORE: -80
        # Analog I/O voltage offset (mV)
        ANALOGIO: -80
      '';

    };
    thermald.enable = false; # throttled and thermald are mutually incompatible.
    power-profiles-daemon.enable =
      true; # Refrain from using the power saver profile.
  };

  system.stateVersion = "22.05";
}
