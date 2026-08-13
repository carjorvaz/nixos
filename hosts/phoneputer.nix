{
  config,
  lib,
  pkgs,
  inputs,
  self,
  ...
}:

let
  phoneKernel = pkgs.callPackage "${inputs.mobile-nixos}/devices/families/sdm845-mainline/kernel" {
    buildPackages = pkgs.buildPackages.buildPackages;
  };
in
{
  nixpkgs.config.allowUnfree = true;
  nixpkgs.overlays = [
    (final: prev: {
      feedbackd-device-themes = prev.feedbackd-device-themes.overrideAttrs (
        lib.optionalAttrs (final.stdenv.buildPlatform.system != final.stdenv.hostPlatform.system) {
          doCheck = false;
        }
      );
      iwd = prev.iwd.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          "${self}/patches/iwd-address-randomization-seed-file.patch"
        ];
      });
      sdm845-alsa-ucm =
        final.runCommand "sdm845-alsa-ucm-current"
          {
            src = final.buildPackages.fetchFromGitLab {
              owner = "sdm845-mainline";
              repo = "alsa-ucm-conf";
              rev = "1b8d290e5aa2ca16b7f2fa8d74910ad19ef88b3a";
              hash = "sha256-Kg4vxDrli/ffNeUwDBL5GfdJsbwFRPAUieQEsjVKADw=";
            };
          }
          ''
            # Nixpkgs supplies the patched generic ucm2/lib helpers.
            mkdir -p "$out/share/alsa/ucm2/OnePlus" "$out/share/alsa/ucm2/conf.d/sdm845"
            cp -r "$src/ucm2/OnePlus/enchilada" "$out/share/alsa/ucm2/OnePlus/enchilada"
            cp -P "$src/ucm2/conf.d/sdm845/OnePlus 6.conf" "$out/share/alsa/ucm2/conf.d/sdm845/"
          '';
    })
  ];
  system.stateVersion = "25.11";

  boot.kernelParams = [ "console=ttyMSM0,115200" ];

  mobile.boot = {
    boot-control.enable = false;
    stage-1.kernel = {
      modular = true;
      package = lib.mkForce (
        phoneKernel.overrideAttrs (old: {
          # The pinned tree predates the stable-tagged WCD934x mic-bias parser fix.
          patches = (old.patches or [ ]) ++ [
            (pkgs.fetchurl {
              url = "https://codeberg.org/sdm845/linux/commit/cfb385a8dc88d86a805a5682eaa68f59fa5c0ec3.patch";
              hash = "sha256-5X+gNf5zwaEFCdk462Poluajxo7QTId6TMCnttSFZ60=";
            })
          ];
        })
      );
      modules = [
        "rmi_core"
        "rmi_i2c"
        "qcom_spmi_haptics"
      ];
    };
  };

  # The current mainline DT uses the standardized vendor/model firmware paths,
  # while Mobile NixOS still packages these blobs under the legacy oneplus6 path.
  mobile.device.firmware = lib.mkForce (
    pkgs.runCommand "oneplus-enchilada-firmware-current-kernel" { } ''
      cp -r ${pkgs.callPackage "${inputs.mobile-nixos}/devices/oneplus-enchilada/firmware" { }}/. "$out"
      chmod -R u+w "$out"
      mkdir -p "$out/lib/firmware/qcom/sdm845/OnePlus" "$out/lib/firmware/qca/OnePlus"
      ln -s ../oneplus6 "$out/lib/firmware/qcom/sdm845/OnePlus/enchilada"
      ln -s ../oneplus6 "$out/lib/firmware/qca/OnePlus/enchilada"
    ''
  );

  hardware.alsa.enablePersistence = false;

  networking = {
    hostName = "phoneputer";
    networkmanager = {
      enable = true;
      wifi.backend = "iwd";
      settings.device."wifi.iwd.autoconnect" = false;
    };
    wireless.iwd = {
      enable = true;
      settings.General = {
        AddressRandomization = "network";
        AddressRandomizationRange = "full";
        AddressRandomizationSeedFile = config.age.secrets.phoneputerIwdMacSeed.path;
        Country = "PT";
      };
    };
  };

  age.secrets = {
    phoneputerIwdMacSeed = {
      file = "${self}/secrets/phoneputerIwdMacSeed.age";
      path = "/run/agenix/phoneputer-iwd-mac-seed";
      owner = "root";
      group = "root";
      mode = "0400";
      symlink = false;
    };
    phoneputerWirelessPrimary = {
      file = "${self}/secrets/phoneputerWirelessPrimary.age";
      path = "/run/NetworkManager/system-connections/phoneputer-primary.nmconnection";
      owner = "root";
      group = "root";
      mode = "0600";
      symlink = false;
    };
    phoneputerWirelessSecondary = {
      file = "${self}/secrets/phoneputerWirelessSecondary.age";
      path = "/run/NetworkManager/system-connections/phoneputer-secondary.nmconnection";
      owner = "root";
      group = "root";
      mode = "0600";
      symlink = false;
    };
  };

  programs.dconf = {
    enable = true;
    profiles.user.databases = [
      {
        settings = {
          "org/gnome/desktop/screensaver" = {
            idle-activation-enabled = false;
            lock-enabled = false;
          };
          "org/gnome/desktop/session".idle-delay = lib.gvariant.mkUint32 0;
          "org/gnome/settings-daemon/plugins/power" = {
            idle-dim = false;
            sleep-inactive-ac-type = "nothing";
            sleep-inactive-battery-type = "nothing";
            sleep-inactive-ac-timeout = lib.gvariant.mkInt32 0;
            sleep-inactive-battery-timeout = lib.gvariant.mkInt32 0;
          };
        };
      }
    ];
  };

  programs.feedbackd.enable = true;

  services = {
    avahi = {
      enable = true;
      nssmdns4 = true;
      publish = {
        enable = true;
        addresses = true;
        workstation = true;
      };
    };
    desktopManager.gnome.enable = true;
    displayManager = {
      autoLogin = {
        enable = true;
        user = "cjv";
      };
      gdm = {
        enable = true;
        autoSuspend = false;
        wayland = true;
      };
    };
    gnome.gnome-keyring.enable = true;
    logind.settings.Login.HandlePowerKey = "ignore";
    neard.enable = true;
    openssh = {
      enable = true;
      settings = {
        KbdInteractiveAuthentication = false;
        PasswordAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };
    pipewire.enable = lib.mkForce false;
    pulseaudio.enable = true;
    udev.extraRules = ''
      # logind can miss the uaccess ACL when the haptic device appears before
      # the graphical seat becomes active. Keep access scoped to vibra devices.
      SUBSYSTEM=="input", KERNEL=="event*", ENV{FEEDBACKD_TYPE}=="vibra", GROUP="feedbackd", MODE="0660"
    '';
    xserver.enable = true;
  };

  systemd = {
    services = {
      # The package does not install a D-Bus activation file, so start its
      # packaged systemd unit explicitly.
      neard.wantedBy = [ "multi-user.target" ];

      NetworkManager = {
        after = [ "iwd.service" ];
        wants = [ "iwd.service" ];
      };
    };

    sleep.extraConfig = ''
      AllowSuspend=no
      AllowHibernation=no
      AllowSuspendThenHibernate=no
      AllowHybridSleep=no
    '';
  };

  environment.gnome.excludePackages = with pkgs; [
    baobab
    cheese
    eog
    epiphany
    evince
    file-roller
    geary
    gnome-calculator
    gnome-calendar
    gnome-characters
    gnome-clocks
    gnome-connections
    gnome-contacts
    gnome-disk-utility
    gnome-font-viewer
    gnome-logs
    gnome-maps
    gnome-music
    gnome-screenshot
    gnome-system-monitor
    gnome-weather
    seahorse
    simple-scan
    totem
    yelp
  ];

  users.users.cjv = {
    isNormalUser = true;
    extraGroups = [
      "feedbackd"
      "networkmanager"
      "wheel"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKabE30sEDKJPK6Oq5zHn80qyakDSMqG3Y5tAfcUs2c9 cjv@air"
    ];
  };

  users.users.root = {
    hashedPassword = "!";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKabE30sEDKJPK6Oq5zHn80qyakDSMqG3Y5tAfcUs2c9 cjv@air"
    ];
  };

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages = with pkgs; [
    alsa-utils
    curl
    ethtool
    git
    gst_all_1.gst-plugins-base
    gst_all_1.gst-plugins-good
    gst_all_1.gstreamer
    iw
    libcamera
    libqmi
    qrtr
    v4l-utils
    vim
    asciiquarium
    kitty
    lazygit
    neovim
    wget
  ];
}
