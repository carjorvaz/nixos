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
    "${self}/profiles/nixos/hardware/panasonic.nix"

    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/bluetooth.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/gpu/intel.nix"
    "${self}/profiles/nixos/iwd.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/laptop.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/cjv.nix"
    "${self}/profiles/nixos/docker.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/graphical/dwm.nix"
    "${self}/profiles/nixos/qmk.nix"
    "${self}/profiles/nixos/ssh.nix"

    # STATE: sudo tailscale up
    "${self}/profiles/nixos/tailscale.nix"
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];

  # Scale of 100% is 96 dpi, steps of 12 are prefered
  services.xserver.dpi = 120;

  networking = {
    # Let iwd handle DHCP for Wi-Fi
    useDHCP = false;

    # But use dhcpcd for ethernet
    interfaces.enp0s31f6.useDHCP = true;

    hostName = "trajanus";
    hostId = "d7ba56e3";
  };

  services = {
    # Reference for i7-8650U: https://kitsunyan.github.io/blog/ulv-adjusting.html
    undervolt = {
      enable = true;
      coreOffset = -90;
      uncoreOffset = -80;
      gpuOffset = -80;
      analogioOffset = -90;
    };

    # Only keep enabled on intel laptops
    thermald.enable = true;
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.11";
}
