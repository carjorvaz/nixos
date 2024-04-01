{ config, lib, pkgs, inputs, ... }:

{
  imports = [
    ./locale.nix
    ./zsh.nix

    # TODO automatically import every module in modules/nixos
    ../../modules/nixos/zfsRemoteUnlock.nix
  ];

  boot.kernelPackages =
    lib.mkDefault config.boot.zfs.package.latestCompatibleLinuxPackages;

  # Disko takes care of filesystem configuration but this
  # is needed because of the impermanence module.
  fileSystems."/persist".neededForBoot = true;

  environment.persistence."/persist" = {
    hideMounts = true;
    files = [ "/etc/machine-id" ];
    directories = [ "/var/db/sudo/lectured" ];
  };

  environment.systemPackages = with pkgs; [
    inputs.agenix.packages."${system}".default
    fd
    file
    git
    pv
    ripgrep
    trash-cli
    tree
    unzip
    wget
  ];

  nix = {
    gc.automatic = true;
    optimise.automatic = true;
    settings = {
      auto-optimise-store = true;
      experimental-features = [ "nix-command" "flakes" ];
    };

    registry = {
      nixpkgs.flake = inputs.nixpkgs;
      unstable.flake = inputs.nixpkgs-unstable;
    };

    nixPath = [
      "nixpkgs=${inputs.nixpkgs.outPath}"
      "unstable=${inputs.nixpkgs-unstable.outPath}"
      "/nix/var/nix/profiles/per-user/root/channels"
    ];
  };

  environment.etc."channels/nixpkgs".source = inputs.nixpkgs.outPath;

  nixpkgs.config.allowUnfree = true;

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

  services.fwupd.enable = true;
  hardware.enableRedistributableFirmware = true;

  # Enable the use of apropos(1).
  documentation.man.generateCaches = true;

  # No mutable users by default
  users.mutableUsers = false;

  # Following section copied from: https://github.com/numtide/srvos/
  systemd = {
    # Given that our systems are headless, emergency mode is useless.
    # We prefer the system to attempt to continue booting so
    # that we can hopefully still access it remotely.
    enableEmergencyMode = false;

    # For more detail, see:
    #   https://0pointer.de/blog/projects/watchdog.html
    watchdog = {
      # systemd will send a signal to the hardware watchdog at half
      # the interval defined here, so every 10s.
      # If the hardware watchdog does not get a signal for 20s,
      # it will forcefully reboot the system.
      runtimeTime = "20s";
      # Forcefully reboot if the final stage of the reboot
      # hangs without progress for more than 30s.
      # For more info, see:
      #   https://utcc.utoronto.ca/~cks/space/blog/linux/SystemdShutdownWatchdog
      rebootTime = "30s";
    };
  };

  # use TCP BBR has significantly increased throughput and reduced latency for connections
  boot.kernel.sysctl = {
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
  };

  # Ensure a clean & sparkling /tmp on fresh boots.
  boot.tmp.cleanOnBoot = lib.mkDefault true;
}
