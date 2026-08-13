{
  config,
  self,
  inputs,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  commonKernelParams = [
    "acpi.ec_no_wakeup=1" # Prevents random wake-ups and fan spin when laptop is shut down
    "amdgpu.dcdebugmask=0x10" # Disables PSR, costing ~1-2W — enable if you see transition flashes
    "amdgpu.abmlevel=0" # Fully disable ABM — abmlevel=2 caused visible shimmer
    "amdgpu.deep_color=0" # Disable 10/12 bpc to prevent temporal dithering
    "i8042.nomux" # Fixes keyboard issues after suspend/resume - https://github.com/sund3RRR/mechrevo14X-linux
    "zfs.zfs_arc_max=4294967296" # Cap ARC at 4 GB — free RAM for browsers and llama.cpp
  ];

  gtt22KernelParams = [
    "ttm.pages_limit=5767168" # Raise AMD APU shared GPU memory to 22 GiB
    "ttm.page_pool_size=5767168"
  ];

  gtt24KernelParams = [
    "ttm.pages_limit=6291456" # Raise AMD APU shared GPU memory to 24 GiB
    "ttm.page_pool_size=6291456"
  ];

  gtt28KernelParams = [
    "ttm.pages_limit=7340032" # Raise AMD APU shared GPU memory to 28 GiB
    "ttm.page_pool_size=7340032"
  ];

  remoteUnlockInterface = "enp103s0f4u1";
  remoteUnlockAddress = "192.168.1.2";
  remoteUnlockGateway = "192.168.1.1";
  remoteUnlockPrefixLength = 24;
in
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
    "${self}/profiles/nixos/dns/blocky-doq.nix"
    "${self}/profiles/nixos/lanzaboote.nix" # STATE: Set up after redeploying
    "${self}/profiles/nixos/laptop.nix"
    "${self}/profiles/nixos/laptopServer.nix"
    "${self}/profiles/nixos/remote-builder.nix"
    # "${self}/profiles/nixos/mullvad.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zfs/backupSource.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/cjv.nix"
    # "${self}/profiles/nixos/claude-deepseek.nix"
    # "${self}/profiles/nixos/podman.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/home-assistant.nix"
    "${self}/profiles/nixos/hermes.nix"
    "${self}/profiles/nixos/nginx/common.nix"
    "${self}/profiles/nixos/valetudo.nix"
    "${self}/profiles/nixos/syncthing.nix"
    "${self}/profiles/nixos/graphical/niri.nix"
    "${self}/profiles/nixos/libvirt.nix"
    "${self}/profiles/nixos/ssh.nix"

    # Local LLM serving (llama-cpp + llm.trajanus.vaz.ovh nginx vhost).
    # BROUGHT DOWN 2026-08-11: vibe-check verdict "not good enough" (dense
    # 27B ~6 t/s; A3B MoE 27 t/s but quality didn't pass). Re-enable by
    # uncommenting; profile retains model paths, quant choices, and the
    # A3B-vs-FF711 swap documentation.
    # NOTE: /models/sota-src (llama.cpp builds) and /models/engines were
    # pruned 2026-08-11 — re-clone and rebuild the Vulkan llama-server
    # binary before re-enabling. Model weights were also deleted
    # (pius:/persist/models/bench/trajanus-llm-experiment-20260811 holds
    # the experiment record; weights are re-downloadable from HF).
    # "${self}/profiles/nixos/local-model.nix"

    # STATE: sudo tailscale up
    # STATE: sudo tailscale set --exit-node=pius
    "${self}/profiles/nixos/tailscale.nix"
  ];

  boot = {
    # Use the Zen4-optimized CachyOS LTO kernel for AMD Ryzen 7 8845HS.
    # Its module closure currently includes nixpkgs' yt6801 driver via
    # autoModules. That driver does not pass the kernel's Clang/LTO module
    # make flags by default, so remote builds fall back to a missing `gcc`.
    # Keep the upstream module enabled, but build it with the same compiler
    # flags as the kernel.
    kernelPackages = pkgs.cachyosKernels.linuxPackages-cachyos-latest-lto-zen4.extend (
      _: prev: {
        yt6801 = prev.yt6801.overrideAttrs (old: {
          makeFlags = (old.makeFlags or [ ]) ++ prev.kernel.commonMakeFlags;
        });
      }
    );

    # Let Raspberry Pi 1 image builds run target ARMv6 helpers when cross-building
    # the SD image locally on trajanus.
    binfmt.emulatedSystems = [ "armv6l-linux" ];

    # Trial automatic boot assessment on trajanus before considering it for
    # other hosts. A new entry gets three attempts; systemd marks it good by
    # reaching boot-complete.target, otherwise systemd-boot can fall back.
    lanzaboote.bootCounting.initialTries = 3;

    initrd.availableKernelModules = [
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
    extraModprobeConfig = ''
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
    # Default to the 28 GiB AMD GTT lane for local LLM Vulkan experiments.
    # trajanus is primarily a lab box now; if normal desktop/server use needs
    # more RAM headroom, boot one of the lower-GTT specialisations below.
    kernelParams = gtt28KernelParams ++ commonKernelParams;

    zfs.extraPools = [ "zdata" ];

    # Carry the local GXxHRXx uniwill_laptop platform-profile patch until this
    # EC-backed quiet/balanced/performance mapping lands upstream. Carry the
    # Realtek out-of-tree r8152 module so the RTL8159 USB 10G NIC binds as
    # Ethernet instead of cdc_ncm, including in initrd for remote unlock.
    extraModulePackages =
      let
        kp = config.boot.kernelPackages;
      in
      [
        (pkgs.callPackage ./trajanus/realtek-r8152.nix {
          kernelPackages = kp;
        })
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
    # claimant we have actually observed on this hardware. Keep cdc_ncm away
    # from the RTL8159 so the vendor r8152 driver can claim it.
    #
    # mt7921e is deliberately NOT blacklisted: blacklisting also denies
    # systemd-modules-load, which left the WiFi card (MediaTek MT7922,
    # PCI 14C3:7922, driven by mt7921e) without a driver at 0000:03:00.0.
    blacklistedKernelModules = [
      "cdc_ncm"
      "eeepc_wmi"
    ];

    # The MT7922 card arrives powered off at 0000:03:00.0 and only
    # initializes once the driver binds, so load it from the initrd: the card
    # is ready early and the initrd has the driver for WiFi remote unlock.
    kernelModules = [ "mt7921e" ];
    initrd.systemd.network.networks."10-${remoteUnlockInterface}" = {
      matchConfig.Name = remoteUnlockInterface;
      networkConfig = {
        Address = "${remoteUnlockAddress}/${toString remoteUnlockPrefixLength}";
        DHCP = "no";
        Gateway = remoteUnlockGateway;
        LinkLocalAddressing = "no";
      };
    };

    # Nothing in the initrd needs network-online.target (sshd unlock only
    # orders after network.target), and wait-online would stall the initrd
    # when the USB NIC is not plugged in. Keep the initrd unblocked.
    initrd.systemd.network.wait-online.enable = false;
  };

  nix.settings.system-features = lib.mkAfter [ "gccarch-armv6kz" ];

  specialisation = {
    llm-vulkan-gtt.configuration = {
      boot.kernelParams = lib.mkForce (gtt22KernelParams ++ commonKernelParams);
    };

    llm-vulkan-gtt24.configuration = {
      boot.kernelParams = lib.mkForce (gtt24KernelParams ++ commonKernelParams);
    };
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

  # Initrd SSH remote unlock for the encrypted zroot pool. trajanus now uses
  # the plugged-in RTL8159 USB 10G NIC for early boot because wpa_supplicant
  # can associate to the home Wi-Fi in initrd but fails PTK installation with
  # mt7921e/nl80211 before SSH becomes reachable.
  cjv.zfsRemoteUnlock = {
    enable = true;
    port = 2222;
    authorizedKeys = config.users.users.root.openssh.authorizedKeys.keys;
    hostKeyFile = "/etc/initrd-hostkey";
    driver = "r8152";
  };

  # Keep the wired unlock NIC on the same static private address after the real
  # system boots. systemd-networkd owns the RTL8159 interface so the LAN rescue
  # address is stable in both initrd and the running system; wifi (iwd +
  # networkd DHCP on 40-wifi) is the fallback when the USB NIC is unplugged.
  networking = {
    useDHCP = false;
    useNetworkd = true;
    networkmanager.enable = false;
    wireless.enable = false;
    # iwd dodges the wpa_supplicant/mt7921e PTK-installation failure. Connect
    # once with `iwctl station wlan0 connect <ssid>`; iwd saves the profile in
    # /var/lib/iwd and auto-connects on every boot (missing AutoConnect in a
    # saved profile defaults to true).
    wireless.iwd = {
      enable = true;
      settings.General = {
        Country = "PT";
      };
    };
  };

  # iwd persists the wifi profile here; without it, the saved connection is
  # wiped on every boot (ZFS root rollback).
  environment.persistence."/persist".directories = [ "/var/lib/iwd" ];
  systemd = {
    network = {
      enable = true;
      networks."10-${remoteUnlockInterface}" = {
        matchConfig.Name = remoteUnlockInterface;
        networkConfig = {
          Address = "${remoteUnlockAddress}/${toString remoteUnlockPrefixLength}";
          DHCP = "no";
          Gateway = remoteUnlockGateway;
          LinkLocalAddressing = "no";
        };
      };
      networks."40-wifi" = {
        # Match by MAC: udev/iwd name the interface wlan0 or wlp3s0 depending
        # on probe order, so a name match is fragile.
        matchConfig.PermanentMACAddress = "60:ff:9e:40:77:0a";
        networkConfig.DHCP = "yes";
        # Required: with wait-online.anyInterface below, boot waits for the
        # wired NIC OR wifi, whichever comes online first. Without this the
        # wifi link is ignored and a boot without the USB NIC stalls 120 s.
        linkConfig.RequiredForOnline = "yes";
      };

      # Boot must not depend on the RTL8159 being plugged in: wait for the
      # first available link (wired or wifi) instead of all of them.
      wait-online.anyInterface = true;
    };

    tmpfiles.rules = [
      "d /models 0775 cjv users -"
      "d /models/incoming 0775 cjv users -"
      "d /models/gguf 0775 cjv users -"
      "d /models/hf-cache 0775 cjv users -"
      "d /models/run-artifacts 0775 cjv users -"
    ];

    services.zfs-models-tuning = {
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
  };

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

  services = {
    # Keep the graphical stack available as an emergency workstation, but require
    # an explicit login so stale compositor sessions do not accumulate unattended.
    displayManager.autoLogin.enable = false;

    tlp.settings = {
      CPU_ENERGY_PERF_POLICY_ON_BAT = lib.mkForce "performance";
      CPU_BOOST_ON_BAT = lib.mkForce 1;
      CPU_HWP_DYN_BOOST_ON_BAT = lib.mkForce 1;
      PCIE_ASPM_ON_BAT = lib.mkForce "performance";
      RUNTIME_PM_ON_BAT = lib.mkForce "on";
      WIFI_PWR_ON_BAT = lib.mkForce "off";
    };

    # keyd: Up arrow = Right Shift on hold, Up on tap
    keyd = {
      enable = true;
      keyboards.internal = {
        ids = [ "k:0001:0001" ]; # AT Translated Set 2 keyboard (internal)
        settings.main = {
          up = "overload(shift, up)";
        };
      };
    };

    # ZFS backup source configuration
    zfsBackup.source = {
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
  };
  powerManagement.powertop.enable = lib.mkForce false;

  graphical.theme.name = "gruvbox";

  environment.systemPackages = [
    pkgs.org-daily-scratch
    pkgs.ethtool
    pkgs.iperf3
    pkgs.python3Packages.huggingface-hub
    pkgs.usbutils
  ];

  age.secrets = {
    trajanusInitrdHostKey = {
      file = "${self}/secrets/trajanusInitrdHostKey.age";
      path = "/etc/initrd-hostkey";
      symlink = false;
    };

    # ZFS backup source configuration
    syncoidSshKey = {
      file = "${self}/secrets/syncoidTrajanusKey.age";
      owner = "syncoid";
      group = "syncoid";
      mode = "0400";
    };

    rustabWebExtCredentials = {
      file = "${self}/secrets/rustabWebExtCredentials.age";
      owner = "cjv";
      group = "users";
      mode = "0400";
    };
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "25.05";
  home-manager.users.cjv = {
    # Home Manager's generated manpage currently triggers upstream options-doc
    # context warnings during NixOS evaluation. Disable only that generated
    # output; the rest of the Home Manager config remains active.
    manual.manpages.enable = false;

    home.stateVersion = "25.05";
    xdg.configFile."waybar/style.css".force = true;
    home.activation.rustabWebExtCredentials =
      inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ]
        ''
          $DRY_RUN_CMD ln -sfn ${config.age.secrets.rustabWebExtCredentials.path} "$HOME/.web-ext-credentials"
        '';
  };
}
