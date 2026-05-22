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
    "${self}/profiles/nixos/acme/dns-vaz-ovh.nix"
    "${self}/profiles/nixos/bluetooth.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/amd.nix"
    "${self}/profiles/nixos/gpu/amd.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/iwd.nix"
    "${self}/profiles/nixos/lanzaboote.nix" # STATE: Set up after redeploying
    "${self}/profiles/nixos/laptop.nix"
    "${self}/profiles/nixos/laptopServer.nix"
    # "${self}/profiles/nixos/mullvad.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zfs/backupSource.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/cjv.nix"
    # "${self}/profiles/nixos/claude-deepseek.nix"
    # "${self}/profiles/nixos/claude-qwen.nix"
    # "${self}/profiles/nixos/podman.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/home-assistant.nix"
    "${self}/profiles/nixos/nginx/common.nix"
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

  # Let Raspberry Pi 1 image builds run target ARMv6 helpers when cross-building
  # the SD image locally on trajanus.
  boot.binfmt.emulatedSystems = [ "armv6l-linux" ];
  nix.settings.system-features = lib.mkAfter [ "gccarch-armv6kz" ];

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

  # Kernel parameters for the GXxHRXx / WUJIE14XA hardware family
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

  specialisation.llm-vulkan-gtt.configuration = {
    boot.kernelParams = [
      # Raise AMD APU shared GPU memory from the default ~15.3 GiB to 22 GiB.
      # This is for dense Qwen3.6-27B Q4-class Vulkan offload experiments.
      "ttm.pages_limit=5767168"
      "ttm.page_pool_size=5767168"
    ];
  };

  networking = {
    hostName = "trajanus";
    hostId = "d7ba56e3";
  };

  # trajanus is the apartment site, so keep its Home Assistant under the
  # host-scoped private namespace for local Bluetooth/BLE devices and apartment
  # LAN integrations such as Valetudo.
  hardware.bluetooth.powerOnBoot = lib.mkForce true;
  cjv.homeAssistant = {
    domain = "home-assistant.trajanus.vaz.ovh";
    homerSubtitle = "Apartment smart home";
    extraComponents = [
      "bluetooth"
      "mqtt"
      "xiaomi_ble"
    ];
    extraConfig.bluetooth = { };
  };

  # TODO: Once trajanus has wired Ethernet, enable cjv.zfsRemoteUnlock with a
  # LAN static IP and initrd SSH host key. Wi-Fi-only initrd unlock is deferred
  # because it is brittle and would pull Wi-Fi credentials into early boot.
  # At the same desk visit, check firmware options: power on after AC loss,
  # disable vendor sleep quirks, and enable Wake-on-LAN once wired.

  boot.zfs.extraPools = [ "zdata" ];

  # Local model store on the spare 1 TB Crucial NVMe.
  # `zdata` can later grow backup/syncoid datasets when trajanus becomes the
  # home server; keep huge GGUF/HF artifacts off the cramped zroot datasets.
  fileSystems."/models" = {
    device = "zdata/models";
    fsType = "zfs";
    options = [
      "zfsutil"
      "nofail"
    ];
  };

  systemd.tmpfiles.rules = [
    "d /models 0775 cjv users -"
    "d /models/incoming 0775 cjv users -"
    "d /models/gguf 0775 cjv users -"
    "d /models/hf-cache 0775 cjv users -"
    "d /models/run-artifacts 0775 cjv users -"
  ];

  systemd.services.zfs-models-tuning = {
    description = "Tune ZFS properties for the local model dataset";
    wantedBy = [ "multi-user.target" ];
    after = [
      "zfs-import-zdata.service"
      "zfs.target"
    ];
    wants = [ "zfs-import-zdata.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if ${pkgs.zfs}/bin/zfs list -H -o name zdata/models >/dev/null 2>&1; then
        ${pkgs.zfs}/bin/zfs set \
          recordsize=1M \
          compression=off \
          primarycache=all \
          logbias=throughput \
          zdata/models
      else
        echo "zdata/models is not available; skipping model dataset tuning"
      fi
    '';
  };

  # Keep the graphical stack available as an emergency workstation, but require
  # an explicit login so stale compositor sessions do not accumulate unattended.
  services.displayManager.autoLogin.enable = false;

  powerManagement.powertop.enable = lib.mkForce false;
  services.tlp.settings = {
    CPU_ENERGY_PERF_POLICY_ON_BAT = lib.mkForce "performance";
    CPU_BOOST_ON_BAT = lib.mkForce 1;
    CPU_HWP_DYN_BOOST_ON_BAT = lib.mkForce 1;
    PCIE_ASPM_ON_BAT = lib.mkForce "performance";
    RUNTIME_PM_ON_BAT = lib.mkForce "on";
    WIFI_PWR_ON_BAT = lib.mkForce "off";
  };

  graphical.theme.name = "gruvbox";

  environment.systemPackages = [
    inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  # Carry the local GXxHRXx uniwill_laptop platform-profile patch until this
  # EC-backed quiet/balanced/performance mapping lands upstream.
  boot.extraModulePackages = let kp = config.boot.kernelPackages; in [
    (pkgs.stdenv.mkDerivation {
      pname = "uniwill-laptop-patched";
      version = kp.kernel.version;
      src = kp.kernel.src;
      patches = [ "${self}/patches/uniwill-laptop-platform-profile-xmg-evo.patch" ];
      nativeBuildInputs = [ pkgs.kmod ] ++ kp.kernel.moduleBuildDependencies;
      makeFlags = kp.kernelModuleMakeFlags ++ [
        "M=$(PWD)/drivers/platform/x86/uniwill"
        "INSTALL_MOD_PATH=$(out)"
      ];
      buildFlags = [ "modules" ];
      installTargets = [ "modules_install" ];
    })
  ];

  # Let uniwill_laptop claim the shared WMI GUID. eeepc_wmi is the competing
  # claimant we have actually observed on this hardware.
  boot.blacklistedKernelModules = [ "eeepc_wmi" ];

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
