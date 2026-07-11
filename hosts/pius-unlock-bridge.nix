{
  inputs,
  lib,
  modulesPath,
  pkgs,
  self,
  ...
}:

{
  imports = [
    (modulesPath + "/installer/sd-card/sd-image-raspberrypi.nix")
  ];

  nixpkgs.hostPlatform = lib.mkDefault lib.systems.examples.raspberryPi;

  image.baseName = "nixos-pius-unlock-bridge-rpi1";
  sdImage.compressImage = true;

  hardware.enableRedistributableFirmware = true;

  boot = {
    # The nixpkgs Raspberry Pi SD-image module still defaults to
    # pkgs.linuxKernel.packages.linux_rpi1, which emits a deprecation warning.
    # Use nixos-hardware's maintained Raspberry Pi kernel expression directly;
    # nixos-hardware does not expose a Raspberry Pi 1 NixOS module.
    kernelPackages = lib.mkForce (
      pkgs.linuxPackagesFor (
        pkgs.callPackage "${inputs.nixos-hardware}/raspberry-pi/common/kernel.nix" {
          rpiVersion = 1;
          argsOverride.kernelPatches = with pkgs.kernelPatches; [
            bridge_stp_helper
            request_key_helper
            {
              name = "pius-unlock-bridge-rpi1-trim-unused-rp1-drivers";
              patch = null;
              structuredExtraConfig = with lib.kernel; {
                # The Raspberry Pi 1 image uses nixos-hardware's rpi1 vendor
                # kernel, whose current defconfig still pulls in a few RP1 /
                # DesignWare drivers that are irrelevant here and fail ARMv6
                # modpost with missing division helpers. Put the config patch
                # directly in the kernel expression override; NixOS-level
                # boot.kernelPatches do not affect this forced kernel package.
                PWM_RP1 = no;
                VIDEO_RP1_CFE_DOWNSTREAM = no;
                I2C_DESIGNWARE_CORE = no;
                I2C_DESIGNWARE_PLATFORM = no;
                SCHED_CLASS_EXT = lib.mkForce no;
              };
            }
          ];
        }
      )
    );

    supportedFilesystems = lib.mkForce {
      btrfs = false;
      cifs = false;
      ext2 = false;
      ext3 = false;
      ext4 = true;
      f2fs = false;
      ntfs = false;
      vfat = true;
      xfs = false;
      zfs = false;
    };

    initrd = {
      availableKernelModules = lib.mkForce [
        "mmc_block"
        "ext4"
        "vfat"
      ];
      kernelModules = lib.mkForce [ ];
      supportedFilesystems = lib.mkForce [
        "ext4"
        "vfat"
      ];
    };

    kernelModules = [
      "smsc95xx" # Raspberry Pi 1/B+ onboard Ethernet
      "mt7601u" # cheap MT7601 USB Wi-Fi fallback
      "rtl8192cu" # TP-Link TL-WN821N v4
    ];

    kernelParams = [
      "console=tty0"
      "console=ttyAMA0,115200n8"
    ];
  };

  networking = {
    hostName = "pius-unlock-bridge";

    # Keep the old Pi interface names predictable for the bridge runbook:
    # eth0 faces pius, wlan0 faces the normal home Wi-Fi.
    usePredictableInterfaceNames = false;
    useDHCP = false;
    dhcpcd.wait = "background";

    interfaces = {
      eth0 = {
        useDHCP = false;
        ipv4.addresses = [
          {
            address = "10.77.0.1";
            prefixLength = 30;
          }
        ];
      };

      wlan0.useDHCP = true;
    };

    wireless = {
      enable = false;

      iwd = {
        enable = true;
        settings = {
          General.Country = "PT";
          Settings.AutoConnect = true;
        };
      };
    };

    firewall = {
      enable = true;
      trustedInterfaces = [ "tailscale0" ];

      # Initial bootstrap can happen over the same point-to-point Ethernet that
      # later faces pius' initrd SSH address.
      interfaces.eth0.allowedTCPPorts = [ 22 ];
    };
  };

  services = {
    openssh = {
      enable = true;
      openFirewall = false;
      hostKeys = [
        {
          path = "/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
      settings = {
        KbdInteractiveAuthentication = false;
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
        StreamLocalBindUnlink = true;
        UseDns = false;
        X11Forwarding = false;
      };
    };

    # First boot: authenticate manually, ideally with a restricted tag:
    #   tailscale up --hostname=pius-unlock-bridge --advertise-tags=tag:pius-unlock-bridge
    tailscale = {
      enable = true;
      openFirewall = true;
      useRoutingFeatures = "client";
    };

    journald.extraConfig = ''
      SystemMaxUse=50M
      RuntimeMaxUse=10M
    '';
  };

  users = {
    mutableUsers = false;
    users.root = {
      # Keep the account usable for SSH public-key auth without creating a known
      # password: this is a hash of a discarded random password, while sshd still
      # has PasswordAuthentication disabled.
      hashedPassword = "$6$wRo72wvMVToo9G4z$bBDagZoJ.ROijqnYw8T8zfBKCNBo5U6MWdYleokqdufEtMruR4PHu.5ujLcC8kioeJzjjMJGRHy98WHmfZSfy.";
      openssh.authorizedKeys.keys = import "${self}/profiles/nixos/ssh-keys.nix";
    };
  };

  environment = {
    defaultPackages = lib.mkForce [ ];
    # The upstream SD-image base profile pulls in efibootmgr, whose efivar
    # dependency is currently broken on armv6l. This Pi boots via firmware+U-Boot,
    # so keep the interactive path explicit and non-EFI.
    systemPackages = lib.mkForce (
      with pkgs;
      [
        iwd
        iproute2
        iputils
        iw
        openssh
        tailscale
        usbutils
      ]
    );
  };

  documentation.enable = false;
  fonts.fontconfig.enable = false;
  xdg = {
    autostart.enable = false;
    icons.enable = false;
    menus.enable = false;
    mime.enable = false;
    sounds.enable = false;
  };

  nix = {
    channel.enable = false;
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      connect-timeout = 5;
      fallback = true;
    };
  };

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  security.sudo.execWheelOnly = true;

  system.stateVersion = "25.11";
}
