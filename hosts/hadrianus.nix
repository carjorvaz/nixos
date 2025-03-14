{
  self,
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  networkInterface = "ens3";
in
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/acme/dns-vaz-one.nix"
    "${self}/profiles/nixos/fail2ban.nix"
    "${self}/profiles/nixos/ghost.nix"
    "${self}/profiles/nixos/mail.nix"
    "${self}/profiles/nixos/nginx/common.nix"
    "${self}/profiles/nixos/nginx/bastion.nix"
    "${self}/profiles/nixos/nginx/blog.nix"
    "${self}/profiles/nixos/ssh.nix"

    # STATE: sudo tailscale up; disable key expiry
    "${self}/profiles/nixos/tailscale.nix"
  ];

  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];

  networking = {
    hostName = "hadrianus";
    hostId = "ce9c10db";
    networkmanager.enable = false;
    useDHCP = false;

    interfaces.${networkInterface} = {
      useDHCP = false;

      ipv4.addresses = [
        {
          address = "46.38.242.172";
          prefixLength = 22;
        }
      ];

      ipv6.addresses = [
        {
          address = "2a03:4000:7:68::";
          prefixLength = 64;
        }
      ];
    };

    defaultGateway = "46.38.240.1";
    defaultGateway6 = {
      address = "fe80::1";
      interface = "ens3";
    };
  };

  # TODO
  # # STATE: Comment this block when deploying, as agenix won't be able to get the
  # # host keys and won't create the boot entry.
  # # After deploying, enable again and rebuild.
  # cjv.zfsRemoteUnlock = {
  #   enable = true;
  #   # Prevent the MitM message by using different host keys in the same host.
  #   port = 2222;
  #   authorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;
  #   hostKeyFile = config.age.secrets.aureliusInitrdHostKey.path; # TODO how to generate key instructions in module
  #   driver = "virtio_pci";
  #   static = {
  #     enable = true;
  #     # Gets the first IP address from the system network configuration.
  #     address = (builtins.head
  #       config.networking.interfaces.${networkInterface}.ipv4.addresses).address;
  #     gateway = config.networking.defaultGateway.address;
  #     # TODO automatically set this according to prefixLength above
  #     netmask = "255.255.252.0";
  #     interface = networkInterface;
  #   };
  # };

  services.tailscale.useRoutingFeatures = "both";

  services.qemuGuest.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "22.11";
}
