{
  self,
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/cpu/amd.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/tailscale.nix" # STATE: sudo tailscale up; disable key expiry; announce exit node
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/ssh.nix"
  ];

  boot.initrd.availableKernelModules = [
    "ahci"
    "ohci_pci"
    "ehci_pci"
    "xhci_pci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [
      "defaults"
      "size=2G"
      "mode=755"
    ];
  };

  fileSystems."/nix" = {
    device = "zroot/local/nix";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/persist" = {
    device = "zroot/safe/persist";
    fsType = "zfs";
    options = [ "zfsutil" ];
    neededForBoot = true;
  };

  fileSystems."/boot1" = {
    device = "/dev/disk/by-uuid/33BC-29B9";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  fileSystems."/boot2" = {
    device = "/dev/disk/by-uuid/3399-302E";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  fileSystems."/boot3" = {
    device = "/dev/disk/by-uuid/3357-70C6";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  fileSystems."/boot4" = {
    device = "/dev/disk/by-uuid/3377-9DD9";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  fileSystems."/boot5" = {
    device = "/dev/disk/by-uuid/33DD-A196";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  boot.loader = {
    efi.canTouchEfiVariables = true;
    grub = {
      enable = true;
      efiSupport = true;
      mirroredBoots = [
        {
          devices = [ "nodev" ];
          path = "/boot1";
        }
        {
          devices = [ "nodev" ];
          path = "/boot2";
        }
        {
          devices = [ "nodev" ];
          path = "/boot3";
        }
        {
          devices = [ "nodev" ];
          path = "/boot4";
        }
        {
          devices = [ "nodev" ];
          path = "/boot5";
        }
      ];
    };
  };

  networking = {
    useDHCP = false;
    hostName = "nerva";
    hostId = "36d0d8f3";

    networkmanager.enable = false;
    wireless.enable = false;

    interfaces.enp2s0 = {
      useDHCP = false;
      wakeOnLan.enable = true; # Requires enabling WoL in BIOS

      ipv4.addresses = [
        {
          address = "192.168.1.2";
          prefixLength = 24;
        }
      ];
    };

    defaultGateway = "192.168.1.254";
  };

  powerManagement.powertop.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.05";
}
