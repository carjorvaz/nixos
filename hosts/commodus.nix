{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ../profiles/nixos/base.nix
    ../profiles/nixos/bootloader/systemd-boot.nix
    ../profiles/nixos/cpu/amd.nix
    ../profiles/nixos/gpu/amd.nix
    ../profiles/nixos/dns/dnscrypt.nix
    ../profiles/nixos/zfs/common.nix
    ../profiles/nixos/zramSwap.nix

    ../profiles/nixos/adb.nix
    ../profiles/nixos/cjv.nix
    ../profiles/nixos/emacs.nix
    ../profiles/nixos/graphical/sway.nix
    ../profiles/nixos/printing.nix
    ../profiles/nixos/qmk.nix
    ../profiles/nixos/scanning.nix

    ../profiles/nixos/acme/dns-vaz-ovh.nix
    ../profiles/nixos/bazarr.nix
    ../profiles/nixos/calibre.nix
    ../profiles/nixos/docker.nix
    ../profiles/nixos/homer.nix
    ../profiles/nixos/jellyfin.nix
    ../profiles/nixos/jellyseerr.nix
    ../profiles/nixos/nextcloud.nix
    ../profiles/nixos/nginx/common.nix
    ../profiles/nixos/prowlarr.nix
    ../profiles/nixos/radarr.nix
    ../profiles/nixos/readarr.nix
    ../profiles/nixos/sonarr.nix
    ../profiles/nixos/ssh.nix

    # STATE: sudo tailscale up; disable key expiry; announce exit node
    ../profiles/nixos/tailscale.nix
    ../profiles/nixos/transmission.nix

    ../profiles/home/zsh.nix
  ];

  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" ];

  networking = {
    useDHCP = false;
    hostName = "commodus";
    hostId = "d82da0d9";

    networkmanager.enable = false;
    wireless.enable = false;

    interfaces.enp10s0 = {
      useDHCP = false;
      wakeOnLan.enable = true; # Requires enabling WoL in BIOS

      ipv4.addresses = [{
        address = "192.168.1.1";
        prefixLength = 24;
      }];
    };

    defaultGateway = "192.168.1.254";
  };

  environment.shellAliases = {
    wakeNerva = "${pkgs.wol}/bin/wol 38:2c:4a:e7:e0:8c";
  };

  # STATE: sudo tailscale up --advertise-exit-node
  # Allows me to use this device as a VPN from other devices (geo-blocking, snooping).
  # Clients should run: sudo tailscale up --exit-node=<exit_node_tailscale_ip>
  services.tailscale.useRoutingFeatures = "both";

  services.nginx.virtualHosts = {
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

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  services.tlp = {
    enable = true;
    settings = {
      # Force battery settings while on AC (power efficiency matters in a home server).
      # https://linrunner.de/tlp/settings/operation.html#tlp-persistent-default
      TLP_DEFAULT_MODE = "BAT";
      TLP_PERSISTENT_DEFAULT = "1";

      # But still let the CPU boost when needed.
      PLATFORM_PROFILE_ON_AC = "balanced";
      PLATFORM_PROFILE_ON_BAT = "balanced";

      CPU_ENERGY_PERF_POLICY_ON_AC = "balance_performance";
      CPU_ENERGY_PERF_POLICY_ON_BAT = "balance_performance";

      CPU_BOOST_ON_AC = "1";
      CPU_BOOST_ON_BAT = "1";

      CPU_HWP_DYN_BOOST_ON_AC = "1";
      CPU_HWP_DYN_BOOST_ON_BAT = "1";
    };
  };

  home-manager.users.cjv = {
    programs.i3status-rust.bars.top.blocks = [
      {
        block = "sound";
        max_vol = 100;
        headphones_indicator = true;
        device_kind = "sink";
        click = [{
          button = "left";
          cmd = "${pkgs.rofi-pulse-select}/bin/rofi-pulse-select sink";
        }];
      }
      {
        block = "time";
        interval = 5;
        format = " $timestamp.datetime(f:'%a %d/%m %R')";
      }
    ];

    wayland.windowManager.sway.config = rec {
      output = { "*".bg = "~/Pictures/wallpaper.jpg fill"; };
    };
  };

  system.stateVersion = "23.05";
}
