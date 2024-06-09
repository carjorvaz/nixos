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
    "${self}/profiles/nixos/gpu/amd.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/tailscale.nix" # STATE: sudo tailscale up
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/adb.nix"
    "${self}/profiles/nixos/cjv.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/graphical/dwm.nix"
    "${self}/profiles/nixos/printing.nix"
    "${self}/profiles/nixos/qmk.nix"
    "${self}/profiles/nixos/scanning.nix"

    "${self}/profiles/home/zsh.nix"
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
  ];

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
          address = "192.168.1.2";
          prefixLength = 24;
        }
      ];
    };

    defaultGateway = "192.168.1.254";
  };

  # Scale of 100% is 96 dpi, steps of 12 are prefered
  services.xserver.dpi = 108;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.05";
}
