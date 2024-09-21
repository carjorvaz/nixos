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

    "${self}/profiles/nixos/virtualbox.nix" # TODO remove after AID

    # STATE: sudo tailscale up
    "${self}/profiles/nixos/tailscale.nix"
  ];

  age.secrets.wgrnlTrajanus = {
    file = "${self}/secrets/wgrnlTrajanus.age";
    owner = "systemd-network";
    group = "systemd-network";
  };

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

    wgrnl = {
      enable = true;
      id = 32;
      ownPrivateKeyFile = config.age.secrets.wgrnlTrajanus.path;
      peerEndpoint = "193.136.164.211:34266";
      peerPubkey = "g08PXxMmzC6HA+Jxd+hJU0zJdI6BaQJZMgUrv2FdLBY=";
    };
  };

  # Only keep enabled on intel laptops
  services.thermald.enable = true;

  home-manager.users.cjv.wayland.windowManager.hyprland.settings = {
    # Enable touchpad acceleration
    device = {
      name = "syna0103:00-06cb:cfb1-touchpad";
      accel_profile = "adaptive";
    };

    monitor = [
      "eDP-1, preferred, auto, 1.5"
      "desc:Iiyama North America PL3293UH 1213432400967, preferred, auto, 1.5"
    ];
  };

  # TODO temporary, delete after ESLE
  # Incompatible with Docker Swarm
  virtualisation.docker.liveRestore = false;
  users.users.cjv.extraGroups = [ "docker" ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.11";
}
