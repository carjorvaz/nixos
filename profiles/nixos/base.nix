{
  self,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  hasManCacheEnable = lib.versionAtLeast lib.version "26.05pre";

  allowedUnfree = [
    "claude-code"
    "discord"
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
({
  imports = [
    "${self}/profiles/nixos/shell/fish.nix"
    "${self}/profiles/nixos/locale.nix"
  ] ++ nixosModules;

  # boot.kernelPackages =
  #   lib.mkDefault config.boot.zfs.package.latestCompatibleLinuxPackages;

  environment.localBinInPath = true;

  environment.systemPackages = with pkgs; [
    inputs.agenix.packages."${pkgs.stdenv.hostPlatform.system}".default
    bubblewrap # for Claude Code sandboxing
    fd
    file
    delta
    gh
    git
    jq
    pv
    ripgrep
    socat # for Claude Code sandboxing
    trash-cli
    tree
    unzip
    wget
    zip
  ];

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
        "https://attic.xuyh0120.win/lantian" # nix-cachyos-kernel
        "https://cache.garnix.io" # nix-cachyos-kernel
        "https://cache.numtide.com" # llm-agents
        "https://lanzaboote.cachix.org"
      ];
      trusted-public-keys = [
        "lantian:EeAUQ+W+6r7EtwnmYjeVwx5kOGEBpjlBfPlzGlTNvHc="
        "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
        "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
        "lanzaboote.cachix.org-1:Nt9//zGmqkg1k5iu+B3bkj3OmHPC30CL3ENQBOH9aVM="
      ];

      # Fail fast if substituters are unreachable.
      connect-timeout = 5;

      # Build from source if any substituter fails, instead of erroring.
      fallback = true;

      # Show more build log lines on failure (default 10 is often too few).
      log-lines = 25;

      # GC trigger: free space until max-free when free drops below min-free.
      min-free = lib.mkDefault (512 * 1024 * 1024);
      max-free = lib.mkDefault (3000 * 1024 * 1024);

      # Remote builders download from caches instead of uploading from here.
      builders-use-substitutes = true;

      # Allow wheel users to use trusted substituters.
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
  };

  environment.etc."channels/nixpkgs".source = inputs.nixpkgs.outPath;

  # Fix /dev/zfs permissions after boot.
  # systemd's kmod-static-nodes.service overwrites ZFS's udev permissions,
  # breaking `zfs allow` delegations for non-root users.
  # Reference: https://discourse.nixos.org/t/dev-zfs-has-the-wrong-permissions-after-rebooting/48737
  environment.etc."tmpfiles.d/zfs.conf".text = ''
    z /dev/zfs 0666 - - -
  '';

  nixpkgs = {
    config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) allowedUnfree;

    overlays = [
      inputs.nix-cachyos-kernel.overlays.pinned
      (final: prev: {
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
  };

  hardware.enableRedistributableFirmware = true;

  services = {
    fwupd.enable = true;
    irqbalance.enable = true;

    # I/O scheduler udev rules: NVMe has built-in scheduling, SSDs benefit
    # from mq-deadline, HDDs from bfq's fair queueing.
    udev.extraRules = ''
      ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
      ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
      ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
    '';

    # Maximize NIC ring buffers for 10Gbps throughput. Fails gracefully if the NIC
    # doesn't support the requested size.
    udev.packages = [
      (pkgs.writeTextFile {
        name = "ethtool-ring-buffer-udev";
        destination = "/etc/udev/rules.d/60-net-ring-buffer.rules";
        text = ''
          ACTION=="add", SUBSYSTEM=="net", KERNEL=="eth*|en*", RUN+="${pkgs.ethtool}/bin/ethtool -G $name rx 4096 tx 4096"
        '';
      })
    ];

    # Limit journal disk usage.
    journald.extraConfig = ''
      SystemMaxUse=50M
      RuntimeMaxUse=10M
    '';
  };

  # Enable the use of apropos(1).

  users = {
    mutableUsers = lib.mkDefault false;

    users.root.hashedPassword = lib.mkDefault "$y$j9T$uuLxhbxqtdSRCjsxgbA2E/$8Y5cHKjUeQTHedJCg1EvX0xoAgML3K9t.XQGQushguD";
  };

  # Only allow wheel group members to execute sudo.
  security.sudo.execWheelOnly = true;
  security.sudo.extraConfig = ''
    Defaults lecture = never
  '';

  # Pre-populate known hosts for common forges (avoids TOFU).
  programs.ssh.knownHosts = {
    "github.com".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
    "gitlab.com".publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfuCHKVTjquxvt6CM6tdG4SLp1Btn/nOeHHE5UOzRdf";
  };

  # Following section copied from: https://github.com/numtide/srvos/
  systemd = {
    # Disable systemd-oomd as it kills processes too eagerly, especially
    # alongside CachyOS's le9 memory management patches.
    # Reference: https://cachyos.org/blog/2025-christmas-new-year/
    oomd.enable = false;

    # Given that our systems are headless, emergency mode is useless.
    # We prefer the system to attempt to continue booting so
    # that we can hopefully still access it remotely.
    enableEmergencyMode = false;

    # For more detail, see:
    #   https://0pointer.de/blog/projects/watchdog.html
    settings.Manager = {
      # systemd will send a signal to the hardware watchdog at half
      # the interval defined here, so every 10s.
      # If the hardware watchdog does not get a signal for 20s,
      # it will forcefully reboot the system.
      RuntimeWatchdogSec = "20s";

      # Forcefully reboot if the final stage of the reboot
      # hangs without progress for more than 30s.
      # For more info, see:
      #   https://utcc.utoronto.ca/~cks/space/blog/linux/SystemdShutdownWatchdog
      RebootWatchdogSec = "30s";

      # CachyOS defaults: faster shutdown and higher file descriptor limits.
      DefaultTimeoutStopSec = "15s";
      DefaultLimitNOFILE = "524288:524288";
    };

    # Disable coredumps (saves disk I/O and space).
    coredump.extraConfig = ''
      Storage=none
      ProcessSizeMax=0
    '';
  };

  boot.kernel.sysctl = {
    # -- Network: TCP congestion control --
    # BBR significantly increases throughput and reduces latency.
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";

    # -- Network: TCP tuning --
    # https://github.com/CachyOS/CachyOS-Settings/blob/master/etc/sysctl.d/99-cachyos-settings.conf
    "net.ipv4.tcp_mtu_probing" = 1;
    "net.ipv4.tcp_fastopen" = 3; # Enable TCP Fast Open for client + server
    "net.ipv4.tcp_slow_start_after_idle" = 0; # Don't restart congestion window after idle
    "net.ipv4.tcp_tw_reuse" = 1; # Reuse TIME_WAIT sockets
    "net.ipv4.tcp_fin_timeout" = 10; # Faster FIN timeout (default 60)
    "net.ipv4.tcp_max_syn_backlog" = 8192;
    "net.ipv4.tcp_keepalive_time" = 60; # Faster keepalive detection (default 7200)
    "net.ipv4.tcp_keepalive_intvl" = 10;
    "net.ipv4.tcp_keepalive_probes" = 6;

    # -- Network: buffer sizes (tuned for 10Gbps) --
    # rmem/wmem max set to 64MB to accommodate high-BDP links (10G * 50ms RTT = 62.5MB).
    # These are maximums — no memory is pre-allocated, TCP autotuning grows as needed.
    "net.core.somaxconn" = 8192;
    "net.core.netdev_max_backlog" = 65536;
    "net.core.netdev_budget" = 600; # Packets per NAPI poll (default 300)
    "net.core.netdev_budget_usecs" = 20000; # Time budget per NAPI poll (default 8000)
    "net.core.rmem_default" = 1048576;
    "net.core.rmem_max" = 67108864;
    "net.core.wmem_default" = 1048576;
    "net.core.wmem_max" = 67108864;
    "net.core.optmem_max" = 65536;
    "net.ipv4.tcp_rmem" = "4096 1048576 67108864";
    "net.ipv4.tcp_wmem" = "4096 65536 67108864";
    "net.ipv4.udp_rmem_min" = 8192;
    "net.ipv4.udp_wmem_min" = 8192;
    "net.ipv4.ip_local_port_range" = "1024 65535"; # Wider ephemeral port range

    # -- VM: dirty page writeback --
    # Reduce disk write latency spikes by limiting dirty page cache size.
    # https://wiki.cachyos.org/configuration/general_system_tweaks/#avoiding-292-second-disk-write-latency-spikes
    "vm.dirty_bytes" = 268435456; # 256 MB
    "vm.dirty_background_bytes" = 67108864; # 64 MB
    "vm.dirty_writeback_centisecs" = 1500; # 15s writeback interval (default 5s)

    # -- VM: memory management --
    "vm.max_map_count" = 2147483642; # Increased for memory-heavy applications
    "vm.compaction_proactiveness" = 0; # Disable proactive compaction (reduces CPU overhead)
    "vm.min_free_kbytes" = 65536; # Keep 64MB free to avoid sudden memory pressure

    # -- Kernel --
    "kernel.nmi_watchdog" = 0; # Disable NMI watchdog (saves a perf counter + power)
    "kernel.printk" = "3 3 3 3"; # Suppress non-critical console messages
    "kernel.kptr_restrict" = 2; # Hide kernel pointers from all users (security hardening)

    # -- Filesystem limits --
    "fs.inotify.max_user_watches" = 524288;
    "fs.inotify.max_user_instances" = 524288;
    "fs.file-max" = 2097152;
  };

  boot.kernelParams = [
    # https://wiki.cachyos.org/configuration/general_system_tweaks/#enable-rcu-lazy
    "rcutree.enable_rcu_lazy=1"

    # https://wiki.cachyos.org/configuration/general_system_tweaks/#transparent-hugepages
    # madvise mode is safe: only apps that explicitly opt in get THP.
    "transparent_hugepage=madvise"

    # Disable zswap — all systems use zram, and having both active causes
    # double-compression (zswap compresses before writing to zram), wasting CPU.
    "zswap.enabled=0"
  ];

  # THP defrag: allow synchronous compaction for madvise requests so apps
  # that opt in reliably get huge pages.
  systemd.tmpfiles.rules = [
    "w! /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise"
  ];

  # Prevent nix builds from starving running services.
  nix.daemonCPUSchedPolicy = "idle";
  nix.daemonIOSchedClass = "idle";
  nix.daemonIOSchedPriority = 7;

  # Prefer killing nix-daemon over running services under memory pressure.
  systemd.services.nix-daemon.serviceConfig.OOMScoreAdjust = lib.mkDefault 250;

  # Apply idle scheduling to nix-gc as well.
  systemd.services.nix-gc.serviceConfig = {
    CPUSchedulingPolicy = "batch";
    IOSchedulingClass = "idle";
    IOSchedulingPriority = 7;
  };

  # Ensure a clean & sparkling /tmp on fresh boots.
  boot.tmp.cleanOnBoot = lib.mkDefault true;
}
// lib.optionalAttrs hasManCacheEnable {
  documentation.man.cache.enable = true;
}
// lib.optionalAttrs (!hasManCacheEnable) {
  documentation.man.generateCaches = true;
})
