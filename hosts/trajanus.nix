{
  config,
  self,
  inputs,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  home-manager.backupFileExtension = "hm-backup";

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
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zfs/backupSource.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/cjv.nix"
    # "${self}/profiles/nixos/claude-deepseek.nix"
    # "${self}/profiles/nixos/claude-qwen.nix"
    # "${self}/profiles/nixos/podman.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/syncthing.nix"
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

  # Conexant SN6140 internal mic fixes:
  # 1. GPIO 0 must be enabled for the mic to produce signal (not just noise).
  #    Upstream fix needed: SND_PCI_QUIRK(0x1d05, 0x137d, ..., CXT_FIXUP_GPIO1)
  #    Card 0 = HDMI (Radeon), Card 1 = Analog (Conexant SN6140)
  # 2. snd_acp_pci (AMD ACP PDM) incorrectly claims this platform has a digital
  #    mic, interfering with the analog internal mic. See:
  #    https://github.com/alsa-project/alsa-ucm-conf/issues/612
  boot.extraModprobeConfig = ''
    options snd-hda-intel model=,gpio1
    blacklist snd_acp_pci
  '';

  # Kernel parameters for TUXEDO/WUJIE14XA hardware
  # Source: https://fnune.com/hardware/2025/07/20/nixos-on-a-tuxedo-infinitybook-pro-14-gen9-amd/
  #
  # Display notes:
  #   - Panel uses DC dimming (no PWM) — no flicker at any brightness level.
  #   - deep_color=0 prevents temporal dithering (frame-by-frame color cycling to
  #     simulate 10/12 bpc on an 8-bit native panel). Costs nothing visually.
  #   - ABM (Adaptive Backlight Management) adjusts backlight + pixel values to save
  #     power. Tried level 2 for battery savings but it caused visible shimmer.
  #   - PSR (Panel Self-Refresh) disabled — saves ~1-2W when enabled, but caused
  #     visual issues. Comment out dcdebugmask to re-enable if battery life matters.
  boot.kernelParams = [
    "acpi.ec_no_wakeup=1" # Prevents random wake-ups and fan spin when laptop is shut down
    "amdgpu.dcdebugmask=0x10" # Disables PSR, costing ~1-2W — enable if you see transition flashes
    "amdgpu.abmlevel=0" # Fully disable ABM — abmlevel=2 caused visible shimmer
    "amdgpu.deep_color=0" # Disable 10/12 bpc to prevent temporal dithering
    "i8042.nomux" # Fixes keyboard issues after suspend/resume - https://github.com/sund3RRR/mechrevo14X-linux
    "zfs.zfs_arc_max=4294967296" # Cap ARC at 4 GB — free RAM for browsers and llama.cpp
  ];

  networking = {
    hostName = "trajanus";
    hostId = "d7ba56e3";
  };

  services.displayManager.autoLogin.user = "cjv";

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

  age.secrets.rustabWebExtCredentials = {
    file = "${self}/secrets/rustabWebExtCredentials.age";
    owner = "cjv";
    group = "users";
    mode = "0400";
  };

  services.zfsBackup.source = {
    enable = true;
    sshKey = config.age.secrets.syncoidSshKey.path;
    targetHosts.pius = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKAJul712iSthWHXLAgBh38x4lpjXgsTd2KzlP5Jnf55";
    # Reuse sanoid snapshots so pius can retain a real backup history.
    # Bookmarks keep incrementals viable even if this roaming laptop misses runs
    # and older source snapshots get pruned before the next sync.
    snapshotMode = "existing";
    createBookmark = true;
    # Skip short-lived 15-minute snapshots on the backup target. Hourly and
    # longer-lived autosnap snapshots still accumulate there.
    excludeSnapshots = [ "^autosnap_.*_frequently$" ];
    # Update pius to the newest eligible snapshot each run instead of sending
    # every intermediate snapshot name. Better suited to roaming links.
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

  system.stateVersion = "25.05";
  home-manager.users.cjv = {
    home.stateVersion = "25.05";
    xdg.configFile."waybar/style.css".force = true;
    home.activation.rustabWebExtCredentials = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD ln -sfn ${config.age.secrets.rustabWebExtCredentials.path} "$HOME/.web-ext-credentials"
    '';
  };
}
