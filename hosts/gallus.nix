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

  boot.initrd.kernelModules = [ "i915" ];
  environment.variables.VDPAU_DRIVER = "va_gl";
  hardware.opengl = {
    enable = true;
    extraPackages = with pkgs; [ vaapiIntel libvdpau-va-gl intel-media-driver ];
  };

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

    fprintd = {
      enable = true;
      tod = {
        enable = true;
        driver = pkgs.libfprint-2-tod1-vfs0090;
      };
    };

    undervolt = {
      enable = true;
      coreOffset = -80;
      gpuOffset = -80;
      uncoreOffset = -80;
      analogioOffset = -80;
    };

    thermald.enable = true;
    power-profiles-daemon.enable =
      true; # Refrain from using the power saver profile.
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
    services.nextcloud-client.enable = true;
  };

  system.stateVersion = "22.05";
}
