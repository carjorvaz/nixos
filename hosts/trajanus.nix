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
    "${self}/profiles/nixos/graphical/hyprland.nix"
    "${self}/profiles/nixos/japaneseKeyboard.nix"
    "${self}/profiles/nixos/qmk.nix"
    "${self}/profiles/nixos/ssh.nix"

    # STATE: sudo tailscale up
    "${self}/profiles/nixos/tailscale.nix"
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usb_storage"
    "sd_mod"
    "sdhci_pci"
  ];

  networking = {
    # Let iwd handle DHCP for Wi-Fi
    useDHCP = false;

    hostName = "trajanus";
    hostId = "d7ba56e3";
  };

  # Only keep enabled on intel laptops
  services.thermald.enable = true;

  # Audio won't work on kernels before 6.6.47
  # https://github.com/nixos/nixpkgs/issues/330685
  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;

  home-manager.users.cjv.wayland.windowManager.hyprland.settings.monitor = [
    "eDP-1,preferred,auto,1.25"
    ",preferred,auto,auto"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.11";
}
