{
  self,
  config,
  lib,
  pkgs,
  inputs,
  options,
  ...
}:

let
  bootstrapPassword = config.cjv.bootstrap.initialHashedPassword;
  loginPasswordFile = config.age.secrets.cjvHashedPassword.path;
  hasCoredumpSettings = options.systemd.coredump ? settings;
  hasManCacheEnable = lib.versionAtLeast lib.version "26.05pre";

  allowedUnfree = [
    "claude-code"
    "discord"
    "ib-tws"
    "ib-tws-unwrapped"
    "intel-ocl"
    "nvidia-persistenced"
    "nvidia-settings"
    "nvidia-x11"
    "open-webui"
  ];

  # Automatically import all .nix files from modules/nixos
  nixosModules =
    let
      moduleDir = "${self}/modules/nixos";
      moduleFiles = builtins.readDir moduleDir;
      nixFiles = lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) moduleFiles;
    in
    lib.mapAttrsToList (name: _: "${moduleDir}/${name}") nixFiles;
in
{
  imports = [
    "${self}/profiles/nixos/shell/fish.nix"
    "${self}/profiles/nixos/locale.nix"
  ]
  ++ nixosModules;

  boot = {
    kernel.sysctl = {
      # -- Network: TCP congestion control --
      # BBR significantly increases throughput and reduces latency.
      "net.core.default_qdisc" = "fq";
      "net.ipv4.tcp_congestion_control" = "bbr";

      # -- Network: TCP tuning --
      "net.ipv4.tcp_mtu_probing" = 1;
      "net.ipv4.tcp_fastopen" = 3;
      "net.ipv4.tcp_slow_start_after_idle" = 0;
      "net.ipv4.tcp_tw_reuse" = 1;
      "net.ipv4.tcp_fin_timeout" = 10;
      "net.ipv4.tcp_max_syn_backlog" = 8192;
      "net.ipv4.tcp_keepalive_time" = 60;
      "net.ipv4.tcp_keepalive_intvl" = 10;
      "net.ipv4.tcp_keepalive_probes" = 6;

      # -- Network: buffer sizes (tuned for 10Gbps) --
      "net.core.somaxconn" = 8192;
      "net.core.netdev_max_backlog" = 65536;
      "net.core.netdev_budget" = 600;
      "net.core.netdev_budget_usecs" = 20000;
      "net.core.rmem_default" = 1048576;
      "net.core.rmem_max" = 67108864;
      "net.core.wmem_default" = 1048576;
      "net.core.wmem_max" = 67108864;
      "net.core.optmem_max" = 65536;
      "net.ipv4.tcp_rmem" = "4096 1048576 67108864";
      "net.ipv4.tcp_wmem" = "4096 65536 67108864";
      "net.ipv4.udp_rmem_min" = 8192;
      "net.ipv4.udp_wmem_min" = 8192;
      "net.ipv4.ip_local_port_range" = "1024 65535";

      # -- VM: dirty page writeback --
      "vm.dirty_bytes" = 268435456;
      "vm.dirty_background_bytes" = 67108864;
      "vm.dirty_writeback_centisecs" = 1500;

      # -- VM: memory management --
      "vm.max_map_count" = 2147483642;
      "vm.compaction_proactiveness" = 0;
      "vm.min_free_kbytes" = 65536;

      # -- Kernel --
      "kernel.nmi_watchdog" = 0;
      "kernel.printk" = "3 3 3 3";
      "kernel.kptr_restrict" = 2;

      # -- Filesystem limits --
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 524288;
      "fs.file-max" = 2097152;
    };

    kernelParams = [
      "rcutree.enable_rcu_lazy=1"
      "transparent_hugepage=madvise"
      "zswap.enabled=0"
    ];

    tmp.cleanOnBoot = lib.mkDefault true;
  };

  environment = {
    localBinInPath = true;

    systemPackages = with pkgs; [
      inputs.agenix.packages."${pkgs.stdenv.hostPlatform.system}".default
      bubblewrap
      fd
      file
      delta
      gh
      git
      jq
      pv
      ripgrep
      socat
      trash-cli
      tree
      unzip
      wget
      zip
    ];

    etc = {
      "channels/nixpkgs".source = inputs.nixpkgs.outPath;

      # Fix /dev/zfs permissions after boot.
      "tmpfiles.d/zfs.conf".text = ''
        z /dev/zfs 0666 - - -
      '';
    };
  };

  nix = {
    channel.enable = lib.mkDefault false;

    gc = {
      automatic = lib.mkDefault true;
      randomizedDelaySec = "14m";
      options = "--delete-older-than 30d";
    };

    settings = {
      auto-optimise-store = true;
      experimental-features = [
        "nix-command"
        "flakes"
      ];

      substituters = [
        "https://attic.xuyh0120.win/lantian"
        "https://cache.garnix.io"
        "https://cache.numtide.com"
        "https://lanzaboote.cachix.org"
      ];
      trusted-public-keys = [
        "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        "lanzaboote.cachix.org-1:Nt9//zGmqkg1k5iu+B3bkj3OmHPC30CL3ENQBOH9aVM="
      ];

      connect-timeout = 5;
      fallback = true;
      log-lines = 25;
      min-free = lib.mkDefault (512 * 1024 * 1024);
      max-free = lib.mkDefault (3000 * 1024 * 1024);
      builders-use-substitutes = true;
      trusted-users = [ "@wheel" ];
    };

    registry = lib.mkDefault {
      nixpkgs.flake = inputs.nixpkgs;
      unstable.flake = inputs.nixpkgs-unstable;
    };

    nixPath = [
      "nixpkgs=${inputs.nixpkgs.outPath}"
      "unstable=${inputs.nixpkgs-unstable.outPath}"
    ];

    daemonCPUSchedPolicy = "idle";
    daemonIOSchedClass = "idle";
    daemonIOSchedPriority = 7;
  };

  nixpkgs = {
    config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) allowedUnfree;

    overlays = [
      inputs.nix-cachyos-kernel.overlays.pinned
      (_final: prev: {
        unstable = import inputs.nixpkgs-unstable {
          system = prev.stdenv.hostPlatform.system;
          config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) allowedUnfree;
        };
      })
    ];
  };

  programs = {
    htop.enable = true;

    neovim = {
      enable = true;
      viAlias = true;
      vimAlias = true;
      defaultEditor = lib.mkDefault true;
    };

    tmux.enable = true;

    # Pre-populate known hosts for common forges (avoids TOFU).
    ssh.knownHosts = {
      "github.com".publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
      "gitlab.com".publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf";
    };
  };

  hardware.enableRedistributableFirmware = true;

  services = {
    fwupd.enable = true;
    irqbalance.enable = true;

    udev.extraRules = ''
      ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
      ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
      ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    '';

    udev.packages = [
      (pkgs.writeTextFile {
        name = "ethtool-ring-buffer-udev";
        destination = "/etc/udev/rules.d/60-net-ring-buffer.rules";
        text = ''
          ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*|en*", RUN+="${pkgs.ethtool}/bin/ethtool -G $name rx 4096 tx 4096"
        '';
      })
    ];

    journald.extraConfig = ''
      SystemMaxUse=50M
      RuntimeMaxUse=10M
    '';
  };

  users = {
    mutableUsers = lib.mkDefault false;

    users.root = lib.mkMerge [
      (lib.mkIf (bootstrapPassword == null) {
        hashedPasswordFile = lib.mkDefault loginPasswordFile;
      })
      (lib.mkIf (bootstrapPassword != null) {
        initialHashedPassword = lib.mkDefault bootstrapPassword;
      })
    ];
  };

  age.secrets.cjvHashedPassword.file = "${self}/secrets/cjvHashedPassword.age";

  security.sudo = {
    execWheelOnly = true;
    extraConfig = ''
      Defaults lecture = never
    '';
  };

  # Following section copied from: https://github.com/numtide/srvos/
  systemd = {
    oomd.enable = false;
    enableEmergencyMode = false;

    settings.Manager = {
      RuntimeWatchdogSec = "20s";
      RebootWatchdogSec = "30s";
      DefaultTimeoutStopSec = "15s";
      DefaultLimitNOFILE = "524288:524288";
    };

    coredump =
      lib.optionalAttrs hasCoredumpSettings {
        settings.Coredump = {
          Storage = "none";
          ProcessSizeMax = "0";
        };
      }
      // lib.optionalAttrs (!hasCoredumpSettings) {
        extraConfig = ''
          Storage=none
          ProcessSizeMax=0
        '';
      };

    # THP defrag: allow synchronous compaction for madvise requests so apps
    # that opt in reliably get huge pages.
    tmpfiles.rules = [
      "w! /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise"
    ];

    services.nix-daemon.serviceConfig.OOMScoreAdjust = lib.mkDefault 250;

    services.nix-gc.serviceConfig = {
      CPUSchedulingPolicy = "batch";
      IOSchedulingClass = "idle";
      IOSchedulingPriority = 7;
    };
  };
}
// lib.optionalAttrs hasManCacheEnable {
  documentation.man.cache.enable = true;
}
// lib.optionalAttrs (!hasManCacheEnable) {
  documentation.man.generateCaches = true;
}
