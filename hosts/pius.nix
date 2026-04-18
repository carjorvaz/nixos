# STATE: Media user migration (from shared `media` user to per-service users)
#   After deploying, run on pius:
#     chown -R sonarr:sonarr /persist/var/lib/sonarr
#     chown -R radarr:radarr /persist/var/lib/radarr
#     chown -R bazarr:bazarr /persist/var/lib/bazarr
#     chown -R jellyfin:jellyfin /persist/var/lib/jellyfin
#     chown -R transmission:transmission /persist/var/lib/transmission
#     chown -R calibre-web:calibre-web /persist/var/lib/calibre-web
#     chgrp -R media /persist/media
#     chmod -R g+rwX /persist/media
#     find /persist/media -type d -exec chmod g+s {} +
#   Then restart affected services:
#     systemctl restart sonarr radarr bazarr jellyfin transmission docker-calibre-web-automated
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
    "${self}/profiles/nixos/server.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/gpu/intel.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/tailscale.nix" # STATE: sudo tailscale up; disable key expiry; announce exit node
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zfs/email.nix"
    "${self}/profiles/nixos/zfs/backupTarget.nix"
    "${self}/profiles/nixos/zramSwap.nix"
    # TODO: Enable after encryption migration (see docs/pius-encryption-migration.md)
    # "${self}/modules/nixos/zfsRemoteUnlock.nix"

    "${self}/profiles/nixos/acme/dns-vaz-ovh.nix"
    "${self}/profiles/nixos/bazarr.nix"
    "${self}/profiles/nixos/cl-olx-scraper.nix"
    "${self}/profiles/nixos/pdf-translator.nix"
    "${self}/profiles/nixos/calibre.nix"
    "${self}/profiles/nixos/docker.nix"
    "${self}/profiles/nixos/home-assistant.nix"
    "${self}/profiles/nixos/homer.nix"
    "${self}/profiles/nixos/jellyfin.nix"
    "${self}/profiles/nixos/jellyseerr.nix"
    "${self}/profiles/nixos/msmtp.nix"
    "${self}/profiles/nixos/nextcloud.nix"
    "${self}/profiles/nixos/nginx/common.nix"
    # "${self}/profiles/nixos/llama-server.nix"
    "${self}/profiles/nixos/open-webui.nix"
    "${self}/profiles/nixos/prowlarr.nix"
    "${self}/profiles/nixos/radarr.nix"
    "${self}/profiles/nixos/recyclarr.nix"
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

  # TODO: Enable after encryption migration (see docs/pius-encryption-migration.md)
  # boot.zfs.requestEncryptionCredentials = true;
  boot.zfs.requestEncryptionCredentials = false;

  networking = {
    hostName = "pius";
    hostId = "b10eb16e";

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
    mode = "400";
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

  # AesSedai Q4_K_M: KLD champion (0.0102), 8.64 tok/s with all flags enabled.
  # Flags benchmarked on 2025-03-02 — best combo: -fa auto -rtr -muge -mqkv --spec-type ngram-mod
  #
  # TODO: Check ubergarm's Qwen3.5-35B-A3B quants when released (IQ4_XSS etc).
  #   https://huggingface.co/ubergarm
  #
  # TODO: When Qwen3.5-0.8B-GGUF is released, download a Q8_0 quant and set
  #   draftModelPath for model-based speculative decoding (same family/tokenizer
  #   = high acceptance rate). See llama-server.nix STATE comments for download.
  #
  # TODO: When ik-llama.cpp gains MTP (Multi-Token Prediction) support, switch
  #   from ngram-mod to --spec-type mtp for ~1.8-2.5x speedup with <1% extra RAM.
  #   Qwen3.5 already ships MTP heads but they're silently skipped today.
  #   Track: https://github.com/ggml-org/llama.cpp/discussions/12130
  # services.llm = {
  #   # backend defaults to "ik-llama"
  #   modelPath = "/persist/models/Qwen3.5-35B-A3B-Q4_K_M-00001-of-00002.gguf";
  #   modelAlias = "qwen3.5-35b-a3b";
  #   threads = 6;           # i5-8400: 6C/6T
  #   contextSize = 65536;   # 64GB RAM with ~10GB used — room to spare
  #   mlock = true;          # lock model in RAM, prevents swapping
  #   enableNginx = true;    # expose via llm.vaz.ovh for opencode on trajanus
  #   reasoningBudget = 0;   # disable thinking — agentic coding gains little from it on CPU
  # };

  # powersave governor (from cpu/intel.nix) already allows full turbo under
  # intel_pstate active mode. hwp_dynamic_boost lets firmware boost more
  # aggressively during sustained load (inference).
  boot.kernelParams = [
    "intel_pstate.hwp_dynamic_boost=1"
    "transparent_hugepage=always" # THP for model weights loaded via --run-time-repack
  ];

  # As a Tailscale exit node, pius enables IPv6 forwarding. Linux only accepts
  # IPv6 router advertisements on forwarding interfaces when accept_ra=2.
  # Without this, pius sees the LAN router but never installs its global IPv6
  # address or default route.
  boot.kernel.sysctl."net.ipv6.conf.enp1s0.accept_ra" = 2;

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
