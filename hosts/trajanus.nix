{
  self,
  lib,
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
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/iwd.nix"
    "${self}/profiles/nixos/laptop.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/cjv.nix"
    "${self}/profiles/nixos/docker.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/graphical/niri.nix"
    "${self}/profiles/nixos/japaneseKeyboard.nix"
    # "${self}/profiles/nixos/qmk.nix"
    "${self}/profiles/nixos/ssh.nix"

    # STATE: sudo tailscale up
    # STATE: sudo tailscale set --exit-node=pius
    "${self}/profiles/nixos/tailscale.nix"
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];

  networking = {
    hostName = "trajanus";
    hostId = "d7ba56e3";
  };

  home-manager.users.cjv = {
    # Panasonic numlock is overlayed on the normal layout
    programs.niri.settings.input.keyboard.numlock = false;

    # Automatic screen brightness
    services.wluma.enable = true;

    wayland.windowManager.hyprland.settings = {
      # Enable touchpad acceleration
      device = {
        name = "syna0103:00-06cb:cfb1-touchpad";
        accel_profile = "adaptive";
      };

      monitor = [
        "eDP-1, preferred, auto, 1.5"
        "desc:Iiyama North America PL3293UH 1213432400967, preferred, auto, 2"
        "desc:Dell Inc. DELL U3419W HW796T2, preferred, auto, 1.6"
      ];

      workspace = [
        "10, monitor:eDP-1, default:true"
      ];
    };
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "25.05";
  home-manager.users.cjv.home.stateVersion = "25.05";
}
