{ self, config, pkgs, lib, suites, ... }:

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
    device = "rpool/local/root";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/F452-C690";
    fsType = "vfat";
  };

  fileSystems."/nix" = {
    device = "rpool/local/nix";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/home" = {
    device = "rpool/safe/home";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/persist" = {
    device = "rpool/safe/persist";
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

    thermald.enable = true;
    undervolt = {
      enable = true;
      coreOffset = -105;
      gpuOffset = -85;
      uncoreOffset = -85;
      analogioOffset = 0;
    };

    # Refrain from using the power saver profile.
    power-profiles-daemon.enable = true;
  };

  services.wgrnl = {
    enable = true;
    privateKeyFile = "/persist/secrets/wireguard/privatekey"; # TODO agenix
  };

  # services.xserver.dpi = 192;
  # environment.variables = {
  #   GDK_SCALE = "2";
  #   GDK_DPI_SCALE = "0.5";
  #   _JAVA_OPTIONS = "-Dsun.java2d.uiScale=2";
  # };

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

  virtualisation.docker.storageDriver = "zfs";

  age.secrets.nebulaRomeGallusCrt.file =
    "${self}/secrets/nebulaRomeGallusCrt.age";
  age.secrets.nebulaRomeGallusKey.file =
    "${self}/secrets/nebulaRomeGallusKey.age";

  services.nebula.networks."rome" = {
    cert = config.age.secrets.nebulaRomeGallusCrt.path;
    key = config.age.secrets.nebulaRomeGallusKey.path;
  };

  system.stateVersion = "22.05";
}
