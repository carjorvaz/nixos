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
    "${self}/profiles/nixos/autoUpgrade.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/gpu/intel.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/laptopServer.nix"
    "${self}/profiles/nixos/tailscale.nix" # STATE: sudo tailscale up; disable key expiry
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/acme/dns-vaz-ovh.nix"
    "${self}/profiles/nixos/frigate.nix"
    "${self}/profiles/nixos/nginx/common.nix"
    "${self}/profiles/nixos/ssh.nix"
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ehci_pci"
    "ahci"
    "usb_storage"
    "sd_mod"
  ];

  networking = {
    useDHCP = false;
    hostName = "t440";
    hostId = "65db7b8e";

    networkmanager.enable = false;

    interfaces.enp0s25 = {
      useDHCP = false;
      wakeOnLan.enable = true; # Requires enabling WoL in BIOS

      ipv4.addresses = [
        {
          address = "192.168.1.1";
          prefixLength = 24;
        }
      ];
    };

    defaultGateway = "192.168.1.254";
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  services.logind.lidSwitch = "ignore";
  powerManagement.powertop.enable = true;

  services.tlp = {
    enable = true;
    settings = {
      START_CHARGE_THRESH_BAT0 = 40;
      STOP_CHARGE_THRESH_BAT0 = 60;
      START_CHARGE_THRESH_BAT1 = 40;
      STOP_CHARGE_THRESH_BAT1 = 60;
    };
  };

  system.stateVersion = "23.05";
}
