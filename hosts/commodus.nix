{ config, lib, pkgs, suites, ... }:

{
  imports = suites.commodus;

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ "i915" ];
  boot.kernelPackages =
    lib.mkDefault config.boot.zfs.package.latestCompatibleLinuxPackages;
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  boot.supportedFilesystems = [ "zfs" ];
  networking.hostId = "d82da0d9";

  fileSystems."/" = {
    device = "zroot/local/root";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/2DF1-138C";
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

  #fileSystems."/media" = {
  #  device = "zmedia/media";
  #  fsType = "zfs";
  #  # options = [ "zfsutil" ]; # TODO passar para não legacy mountpoint (?)
  #};

  #fileSystems."/mirror" = {
  #  device = "zmirror/mirror";
  #  fsType = "zfs";
  #  options = [ "zfsutil" ];
  #};

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
  };

  networking = {
    useDHCP = false;

    interfaces.enp2s0 = {
      useDHCP = false;
      wakeOnLan.enable = true;

      ipv4.addresses = [{
        address = "192.168.1.1";
        prefixLength = 24;
      }];
    };

    defaultGateway = "192.168.1.254";
  };

  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  hardware.video.hidpi.enable = lib.mkDefault true;

  environment.variables.VDPAU_DRIVER = "va_gl";
  hardware.opengl = {
    enable = true;
    extraPackages = with pkgs; [ vaapiIntel libvdpau-va-gl intel-media-driver ];
  };

  services.kanata.keyboards."colemak".devices =
    [ "/dev/input/by-id/usb-04d9_USB_Keyboard-if01-event-kbd" ];

  home-manager.users.cjv = {
    programs.i3status-rust.bars.top.blocks = [
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
        block = "time";
        interval = 5;
        format = "%a %d/%m %R";
      }
    ];

    wayland.windowManager.sway.config = rec {
      output = {
        "*".bg = "~/Pictures/wallpaper.jpg fill";
        "HDMI-A-1" = { resolution = "1920x1080"; };
        "HDMI-A-2" = { resolution = "1920x1080"; };
      };

      workspaceOutputAssign = [{
        workspace = "9";
        output = "HDMI-A-2";
      }];
    };

    services.nextcloud-client.enable = true;
  };

  system.stateVersion = "22.05";
}
