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
    "${self}/profiles/nixos/graphical/hyprland.nix"
    "${self}/profiles/nixos/japaneseKeyboard.nix"
    "${self}/profiles/nixos/libvirt.nix"
    "${self}/profiles/nixos/printing.nix"
    "${self}/profiles/nixos/qmk.nix"
    "${self}/profiles/nixos/scanning.nix"
    "${self}/profiles/nixos/ssh.nix"

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

    interfaces.enp11s0 = {
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

  # Blacklist GT 710. Leave it for VFIO.
  boot.extraModprobeConfig = ''
    blacklist nouveau
    options nouveau modeset=0
  '';

  services.udev.extraRules = ''
    # Remove NVIDIA USB xHCI Host Controller devices, if present
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c0330", ATTR{power/control}="auto", ATTR{remove}="1"
    # Remove NVIDIA USB Type-C UCSI devices, if present
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c8000", ATTR{power/control}="auto", ATTR{remove}="1"
    # Remove NVIDIA Audio devices, if present
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", ATTR{power/control}="auto", ATTR{remove}="1"
    # Remove NVIDIA VGA/3D controller devices
    ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x03[0-9]*", ATTR{power/control}="auto", ATTR{remove}="1"
  '';

  boot.blacklistedKernelModules = [
    "nouveau"
    "nvidia"
    "nvidia_drm"
    "nvidia_modeset"
  ];

  home-manager.users.cjv.wayland.windowManager.hyprland.settings.monitor = [
    "HDMI-A-1, preferred, auto, 1.6"
    "Unknown-1, disable"
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.05";
}
