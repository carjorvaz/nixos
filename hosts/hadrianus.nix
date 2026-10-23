{
  self,
  config,
  lib,
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
    "${self}/profiles/nixos/server.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/dns/blocky-doq.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zfs/email.nix"
    "${self}/profiles/nixos/zfs/backupSource.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/acme/dns-vaz-one.nix"
    "${self}/profiles/nixos/fail2ban.nix"
    "${self}/profiles/nixos/mail.nix"
    "${self}/profiles/nixos/nginx/common.nix"
    "${self}/profiles/nixos/nginx/bastion.nix"
    "${self}/profiles/nixos/terreno-bastion.nix"
    "${self}/profiles/nixos/nginx/blog.nix"
    "${self}/profiles/nixos/ssh.nix"
    "${self}/profiles/nixos/umami.nix"

    # ntfy and ultimate-tic-tac-toe are unused; on this 2 GB host their
    # resident memory (~350 MB) is needed by mail and DNS.

    # STATE: sudo tailscale up; disable key expiry
    "${self}/profiles/nixos/tailscale.nix"
  ];

  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "virtio_pci"
    "virtio_net"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];

  # This VM has 2 GB of RAM. The default ARC cap (~60% of RAM) plus the mail,
  # DNS and web stack left no headroom, so the nightly nix-gc store walk pushed
  # the kernel into global OOM kills. Cap ARC at 384 MiB.
  boot.kernelParams = [ "zfs.zfs_arc_max=402653184" ];

  # The Redis NixOS module (pulled in for rspamd) sets this to 1, which makes
  # the kernel never refuse an allocation and turns memory pressure into random
  # OOM kills instead of a failing allocation. Use the heuristic instead.
  boot.kernel.sysctl."vm.overcommit_memory" = lib.mkForce 0;

  systemd = {
    # zram is the only swap device here, and its compressed pool is not
    # charged to any cgroup, so the kernel OOM path is the only failure mode:
    # thin provisioning can keep should_reclaim_retry() spinning instead of
    # killing. oomd turns sustained PSI pressure into a clean kill. base.nix
    # disables it (srvos default), and `enable` alone configures no kill target.
    oomd = {
      enable = lib.mkForce true;
      enableSystemSlice = true;
    };

    # oomd monitors system.slice; keep DNS, the web edge and remote access out
    # of its victim pool. Mail units are marked in profiles/nixos/mail.nix.
    services = {
      blocky.serviceConfig.ManagedOOMPreference = "avoid";
      unbound.serviceConfig.ManagedOOMPreference = "avoid";
      nginx.serviceConfig.ManagedOOMPreference = "avoid";
      tailscaled.serviceConfig.ManagedOOMPreference = "avoid";
      sshd.serviceConfig.ManagedOOMPreference = "avoid";

      # base.nix marks nix-daemon as a preferred OOM victim (+250). On this
      # 2 GB host that made store imports the first casualty; keep it below
      # mail (-800) but not the default victim.
      nix-daemon.serviceConfig.OOMScoreAdjust = lib.mkForce (-200);
    };
  };

  networking = {
    hostName = "hadrianus";
    hostId = "ce9c10db";

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

    defaultGateway = {
      address = "46.38.240.1";
      interface = networkInterface;
    };
    defaultGateway6 = {
      address = "fe80::1";
      interface = "ens3";
    };
  };

  age.secrets = {
    # https://nixos.wiki/wiki/Agenix#Using_secrets_in_initrd
    hadrianusInitrdHostKey = {
      file = "${self}/secrets/hadrianusInitrdHostKey.age";
      path = "/etc/initrd-hostkey";
      symlink = false;
    };

    # ZFS backup source configuration
    syncoidSshKey = {
      file = "${self}/secrets/syncoidHadrianusKey.age";
      owner = "syncoid";
      group = "syncoid";
      mode = "0400";
    };
  };

  # STATE: Comment this block when deploying, as agenix won't be able to get the
  # host keys and won't create the boot entry.
  # After deploying, enable again and rebuild.
  # Same steps if adding a new secret: add secret, rebuild with commented block, then rebuild properly with block.
  cjv.zfsRemoteUnlock = {
    enable = true;
    # Prevent the MitM message by using different host keys in the same host.
    port = 2222;
    authorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;

    # https://nixos.wiki/wiki/Agenix#Using_secrets_in_initrd
    hostKeyFile = "/etc/initrd-hostkey";

    driver = "virtio_net";
    static = {
      enable = true;
      # Gets the first IP address from the system network configuration.
      inherit ((builtins.head config.networking.interfaces.${networkInterface}.ipv4.addresses)) address;
      gateway = config.networking.defaultGateway.address;
      # TODO automatically set this according to prefixLength above
      netmask = "255.255.252.0";
      interface = networkInterface;
    };
  };

  services = {
    tailscale.useRoutingFeatures = "both";
    qemuGuest.enable = true;

    # ZFS backup source configuration
    zfsBackup.source = {
      enable = true;
      sshKey = config.age.secrets.syncoidSshKey.path;
      targetHosts.pius = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55";
      datasets."zroot/safe" = {
        target = "syncoid@pius:zsafe/backups/hadrianus";
        recursive = true;
        # Decrypt on source, encrypt in transit via SSH.
        # Stored unencrypted unless target dataset has encryption enabled.
        sendOptions = "";
      };
    };
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "22.11";
}
