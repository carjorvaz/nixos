{
  config,
  self,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")

    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/bluetooth.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/amd.nix"
    "${self}/profiles/nixos/gpu/amd.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/iwd.nix"
    "${self}/profiles/nixos/lanzaboote.nix" # STATE: Set up after redeploying
    "${self}/profiles/nixos/laptop.nix"
    # "${self}/profiles/nixos/mullvad.nix"
    "${self}/profiles/nixos/tuxedo.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zfs/backupSource.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/cjv.nix"
    # "${self}/profiles/nixos/podman.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/graphical/niri.nix"
    "${self}/profiles/nixos/libvirt.nix"
    "${self}/profiles/nixos/ssh.nix"

    # STATE: sudo tailscale up
    # STATE: sudo tailscale set --exit-node=pius
    "${self}/profiles/nixos/tailscale.nix"
  ];

  # Use Zen4-optimized kernel for AMD Ryzen 7 8845HS
  boot.kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-lto-zen4;

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "thunderbolt"
    "nvme"
    "usb_storage"
    "sd_mod"
  ];

  # Kernel parameters for TUXEDO/WUJIE14XA hardware
  # Source: https://fnune.com/hardware/2025/07/20/nixos-on-a-tuxedo-infinitybook-pro-14-gen9-amd/
  boot.kernelParams = [
    "acpi.ec_no_wakeup=1" # Prevents random wake-ups and fan spin when laptop is shut down
    "amdgpu.dcdebugmask=0x10" # Fixes Wayland performance issues
    "amdgpu.abmlevel=0" # Disable Adaptive Backlight Management (prevents flickering/dithering)
    "amdgpu.deep_color=0" # Disable 10/12 bpc to prevent temporal dithering
    "i8042.nomux" # Fixes keyboard issues after suspend/resume - https://github.com/sund3RRR/mechrevo14X-linux
  ];

  networking = {
    hostName = "trajanus";
    hostId = "d7ba56e3";
  };

  services.displayManager.autoLogin.user = "cjv";

  home-manager.users.cjv = {
    wayland.windowManager.hyprland.settings.workspace = [
      "10, monitor:eDP-1, default:true"
    ];
  };

  # keyd: Up arrow = Right Shift on hold, Up on tap
  services.keyd = {
    enable = true;
    keyboards.internal = {
      ids = [ "k:0001:0001" ];  # AT Translated Set 2 keyboard (internal)
      settings.main = {
        up = "overload(shift, up)";
      };
    };
  };

  # ZFS backup source configuration
  age.secrets.syncoidSshKey = {
    file = "${self}/secrets/syncoidTrajanusKey.age";
    owner = "syncoid";
    group = "syncoid";
    mode = "0400";
  };

  services.zfsBackup.source = {
    enable = true;
    sshKey = config.age.secrets.syncoidSshKey.path;
    targetHosts.pius = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55";
    # Send each snapshot individually instead of streaming.
    # If interrupted, completed snapshots are preserved - much more robust for roaming.
    noStream = true;
    datasets."zroot/safe" = {
      target = "syncoid@pius:zsafe/backups/trajanus";
      recursive = true;
      # Decrypt on source, encrypt in transit via SSH.
      # Stored unencrypted unless target dataset has encryption enabled.
      sendOptions = "";
    };
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # FIXME: Remove once https://github.com/NixOS/nixpkgs/commit/15d9ec6 is fixed upstream.
  # The commit incorrectly placed lib.mkIf inside a list literal for services.udev.packages.
  services.udev.packages =
    let
      cfg = config.hardware.tuxedo-drivers;
      tuxedo-drivers = config.boot.kernelPackages.tuxedo-drivers;
      optUdevRule = path: value:
        lib.optional (value != null)
          ''ACTION=="add", SUBSYSTEM=="platform", DRIVER=="tuxedo_keyboard", ATTR{${path}}="${value}"'';
    in
    lib.mkIf cfg.enable (
      lib.mkForce (
        [ tuxedo-drivers ]
        ++ lib.optional (lib.any (v: v != null) (lib.attrValues cfg.settings)) (
          pkgs.writeTextDir "etc/udev/rules.d/90-tuxedo.rules" (
            lib.concatLines (
              [ "# Custom rules for TUXEDO laptops" ]
              ++ (optUdevRule "charging_profile/charging_profile" cfg.settings.charging-profile)
              ++ (optUdevRule "charging_priority/charging_prio" cfg.settings.charging-priority)
              ++ (optUdevRule "fn_lock" cfg.settings.fn-lock)
            )
          )
        )
      )
    );

  system.stateVersion = "25.05";
  home-manager.users.cjv.home.stateVersion = "25.05";
}
