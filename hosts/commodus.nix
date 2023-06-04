{ self, config, lib, pkgs, suites, ... }:

{
  imports = suites.commodus;

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ "i915" ];
  boot.kernelPackages = pkgs.linuxPackages_xanmod;
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

    interfaces.eno1 = {
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
        output = "HDMI-A-3";
      }];
    };
  };

  virtualisation.docker.storageDriver = "zfs";

  # STATE: sudo tailscale up --advertise-exit-node
  # Allows me to use this device as a VPN from other devices (geo-blocking, snooping).
  # Clients should run: sudo tailscale up --exit-node=<exit_node_tailscale_ip>
  services.tailscale.useRoutingFeatures = "both";

  system.stateVersion = "22.05";
}
