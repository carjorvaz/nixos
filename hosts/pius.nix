{
  self,
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  # TODO
  # - cups printing server

  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/autoUpgrade.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/gpu/intel.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/tailscale.nix" # STATE: sudo tailscale up; disable key expiry; announce exit node
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/acme/dns-vaz-ovh.nix"
    "${self}/profiles/nixos/bazarr.nix"
    "${self}/profiles/nixos/calibre.nix"
    "${self}/profiles/nixos/docker.nix"
    "${self}/profiles/nixos/homer.nix"
    "${self}/profiles/nixos/jellyfin.nix"
    "${self}/profiles/nixos/jellyseerr.nix"
    "${self}/profiles/nixos/msmtp.nix"
    "${self}/profiles/nixos/nextcloud.nix"
    "${self}/profiles/nixos/nginx/common.nix"
    "${self}/profiles/nixos/plausible.nix"
    "${self}/profiles/nixos/prowlarr.nix"
    "${self}/profiles/nixos/radarr.nix"
    "${self}/profiles/nixos/readarr.nix"
    "${self}/profiles/nixos/sonarr.nix"
    "${self}/profiles/nixos/ssh.nix"
    "${self}/profiles/nixos/transmission.nix"
  ];

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];

  networking = {
    useDHCP = false;
    hostName = "pius";
    hostId = "b10eb16e";

    networkmanager.enable = false;
    wireless.enable = false;

    interfaces.enp1s0 = {
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

  environment.shellAliases = {
    wakeNerva = "${pkgs.wol}/bin/wol 38:2c:4a:e7:e0:8c";
    wakeCommodus = "${pkgs.wol}/bin/wol 00:68:eb:cd:f5:31";
  };

  services = {
    nginx.virtualHosts = {
      # TODO (3d printer)
      "printer.vaz.ovh" = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/".proxyPass = "http://192.168.1.73:10088";
      };

      "router.vaz.ovh" = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/".proxyPass = "http://192.168.1.254";
      };
    };

    # STATE: sudo tailscale up --advertise-exit-node
    # Allows this device to be used as a VPN from other devices (geo-blocking, snooping).
    # Clients should run: sudo tailscale up --exit-node=<exit_node_tailscale_ip>
    tailscale.useRoutingFeatures = "both";
  };

  powerManagement.powertop.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.05";
}
