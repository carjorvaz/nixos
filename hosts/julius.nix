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
    "${self}/profiles/nixos/server.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/gpu/intel.nix"
    "${self}/profiles/nixos/dns/blocky-doq.nix"
    "${self}/profiles/nixos/laptopServer.nix"
    "${self}/profiles/nixos/ssh.nix"
    "${self}/profiles/nixos/tailscale.nix" # STATE: sudo tailscale up; disable key expiry
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/acme/dns-vaz-ovh.nix"
    "${self}/profiles/nixos/frigate.nix"
    "${self}/profiles/nixos/nginx/common.nix"
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];

  # zram is the only swap device; oomd kills the pressure source before the
  # kernel spins in reclaim. Frigate is the intended victim (recordings resume);
  # the gateway/DNS/mesh units must survive.
  systemd = {
    oomd = {
      enable = lib.mkForce true;
      enableSystemSlice = true;
    };

    services = {
      blocky.serviceConfig.ManagedOOMPreference = "avoid";
      tailscaled.serviceConfig.ManagedOOMPreference = "avoid";
      nginx.serviceConfig.ManagedOOMPreference = "avoid";
      sshd.serviceConfig.ManagedOOMPreference = "avoid";
    };
  };

  networking = {
    hostName = "julius";
    hostId = "236fb370";

    interfaces.enp0s31f6 = {
      useDHCP = false;
      wakeOnLan.enable = true; # Requires enabling WoL in BIOS

      ipv4.addresses = [
        {
          address = "192.168.1.1";
          prefixLength = 24;
        }
      ];
    };

    # networkd requires the default gateway to name its interface.
    defaultGateway = {
      address = "192.168.1.254";
      interface = "enp0s31f6";
    };
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "25.05";
}
