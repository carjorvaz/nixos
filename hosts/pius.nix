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
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/gpu/intel.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/tailscale.nix" # STATE: sudo tailscale up; disable key expiry; announce exit node
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zfs/email.nix"
    "${self}/profiles/nixos/zfs/backupTarget.nix"
    "${self}/profiles/nixos/zramSwap.nix"
    "${self}/profiles/nixos/acme/dns-vaz-ovh.nix"
    "${self}/profiles/nixos/bazarr.nix"
    "${self}/profiles/nixos/cl-olx-scraper.nix"
    "${self}/profiles/nixos/pdf-translator.nix"
    "${self}/profiles/nixos/calibre.nix"
    "${self}/profiles/nixos/docker.nix"
    "${self}/profiles/nixos/home-assistant.nix"
    # "${self}/profiles/nixos/homer.nix"
    "${self}/profiles/nixos/jellyfin.nix"
    "${self}/profiles/nixos/jellyseerr.nix"
    "${self}/profiles/nixos/msmtp.nix"
    "${self}/profiles/nixos/nextcloud.nix"
    "${self}/profiles/nixos/nginx/common.nix"
    # "${self}/profiles/nixos/llama-server.nix"
    "${self}/profiles/nixos/open-webui.nix"
    "${self}/profiles/nixos/prowlarr.nix"
    "${self}/profiles/nixos/radarr.nix"
    "${self}/profiles/nixos/samba.nix"
    "${self}/profiles/nixos/searx.nix"
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

  boot.zfs.requestEncryptionCredentials = false;

  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-server-lto;
  boot.zfs.package = config.boot.kernelPackages.zfs_cachyos;

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
          address = "192.168.1.3";
          prefixLength = 24;
        }
      ];
    };

    defaultGateway = "192.168.1.1";
  };

  environment.shellAliases = {
    wakeNerva = "${pkgs.wol}/bin/wol 38:2c:4a:e7:e0:8c";
    wakeCommodus = "${pkgs.wol}/bin/wol 00:68:eb:cd:f5:31";
  };

  services = {
    nginx.virtualHosts = {
      "router.vaz.ovh" = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/".proxyPass = "http://192.168.1.1";
      };
    };

    # STATE: sudo tailscale up --advertise-exit-node
    # Allows this device to be used as a VPN from other devices (geo-blocking, snooping).
    # Clients should run: sudo tailscale up --exit-node=<exit_node_tailscale_ip>
    tailscale.useRoutingFeatures = "both";
  };

  age.secrets.mailPiusPassword = {
    file = "${self}/secrets/mailPiusPassword.age";
    mode = "444";
  };

  programs.msmtp.accounts.default = {
    auth = true;
    aliases = "/etc/aliases";
    user = "pius@carjorvaz.com";
    from = "pius <pius@carjorvaz.com>";
    host = "mail.vaz.one";
    passwordeval = "${pkgs.coreutils}/bin/cat ${config.age.secrets.mailPiusPassword.path}";
  };

  powerManagement.powertop.enable = true;

  # ZFS backup target configuration
  # STATE: After first deploy, create the backup dataset:
  #   zfs create -o mountpoint=/mnt/backups zsafe/backups
  services.zfsBackup.target = {
    enable = true;
    # Add SSH public keys from source machines' syncoid users here
    sshPublicKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJrrIpOBpX03+punCUL8ODQiqNuQ//RBdUNxIaLt+x0w syncoid@hadrianus"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIKG4viU84jy3jZj2yvk9Esyem8pgkHGQnAHmDgTxdtK syncoid@trajanus"
    ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.05";
}
