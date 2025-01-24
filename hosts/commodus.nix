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
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/amd.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/tailscale.nix" # STATE: sudo tailscale up
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/adb.nix"
    "${self}/profiles/nixos/cjv.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/graphical/gnome.nix"
    "${self}/profiles/nixos/libvirt.nix"
    "${self}/profiles/nixos/printing.nix"
    "${self}/profiles/nixos/qmk.nix"
    "${self}/profiles/nixos/scanning.nix"
    "${self}/profiles/nixos/ssh.nix"

    "${self}/profiles/home/zsh.nix"
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];

  # Would make it unbootable remotely because of backups
  boot.zfs.requestEncryptionCredentials = false;

  networking = {
    useDHCP = false;
    hostName = "commodus";
    hostId = "d82da0d9";

    networkmanager.enable = false;
    wireless.enable = false;

    interfaces.enp10s0 = {
      useDHCP = false;
      wakeOnLan.enable = true; # Requires enabling WoL in BIOS

      ipv4.addresses = [
        {
          address = "192.168.1.3";
          prefixLength = 24;
        }
      ];
    };

    defaultGateway = "192.168.1.254";
  };

  home-manager.users.cjv.wayland.windowManager.hyprland.settings.monitor = [
    "HDMI-A-1, preferred, auto, 1.6"
    "Unknown-1, disable"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.05";
}
