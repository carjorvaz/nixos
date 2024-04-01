{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ../profiles/nixos/base.nix
    ../profiles/nixos/bootloader/systemd-boot.nix
    ../profiles/nixos/iwctl.nix
    ../profiles/nixos/dns/dnscrypt.nix
    ../profiles/nixos/laptop.nix
    ../profiles/nixos/zfs/common.nix
    ../profiles/nixos/zramSwap.nix

    ../profiles/nixos/cjv.nix
    ../profiles/nixos/docker.nix
    ../profiles/nixos/emacs.nix
    ../profiles/nixos/graphical/sway.nix
    ../profiles/nixos/qmk.nix
    ../profiles/nixos/ssh.nix

    # STATE: sudo tailscale up
    ../profiles/nixos/tailscale.nix
  ];

  users.mutableUsers = true;

  hardware.asahi = {
    withRust = true;
    useExperimentalGPUDriver = true;
    experimentalGPUInstallMode = "replace";

    setupAsahiSound = true;

    # TODO really big files taking up space in the repo, think of better alternative
    peripheralFirmwareDirectory = ./asahi-firmware;
  };

  # # TODO ZFS impermanence; requires redeploy with snapshot after creation
  # boot = {
  #   initrd = {
  #     systemd.enable = false;
  #     postDeviceCommands = lib.mkAfter ''
  #       zfs rollback -r zroot/local/root@blank
  #     '';
  #   };

  #   plymouth.enable = false;
  # };

  boot.loader.efi.canTouchEfiVariables = false;
  boot.initrd.availableKernelModules = [ "usb_storage" ];
  boot.extraModprobeConfig = ''
    options hid_apple fnmode=2 iso_layout=1 swap_opt_cmd=1 swap_fn_leftctrl=1
  '';

  fileSystems = {
    "/" = {
      device = "rpool/local/root";
      fsType = "zfs";
      options = [ "zfsutil" ];
    };

    "/nix" = {
      device = "rpool/local/nix";
      fsType = "zfs";
      options = [ "zfsutil" ];
    };
    "/home" = {
      device = "rpool/safe/home";
      fsType = "zfs";
      options = [ "zfsutil" ];
    };
    "/persist" = {
      device = "rpool/safe/persist";
      fsType = "zfs";
      options = [ "zfsutil" ];
    };

    "/boot" = {
      device = "/dev/disk/by-uuid/7F0A-1A0F";
      fsType = "vfat";
    };
  };

  networking = {
    useDHCP = true;
    hostName = "trajanus";
    hostId = "d7ba56e3";

    networkmanager.enable = false;
  };

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  home-manager.users.cjv = {
    programs.i3status-rust.bars.top.blocks = [
      # {
      #   block = "bluetooth";
      #   mac = ""; # TODO
      #   click = [{
      #     button = "left";
      #     cmd = "${pkgs.rofi-bluetooth}/bin/rofi-bluetooth &";
      #   }];
      # }
      { block = "battery"; }
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
        block = "sound";
        max_vol = 100;
        device_kind = "source";
        click = [{
          button = "left";
          cmd = "${pkgs.rofi-pulse-select}/bin/rofi-pulse-select source";
        }];
      }
      {
        block = "time";
        interval = 5;
        format = " $timestamp.datetime(f:'%a %d/%m %R')";
      }
    ];

    # TODO
    # services.kanshi = {
    #   enable = true;

    #   profiles = {

    #     # Configuration file
    #     # Each output profile is delimited by brackets. It contains several output directives (whose syntax is similar to sway-output(5)). A profile will be enabled if all of the listed outputs are connected.

    #     # profile {
    #     # 	output LVDS-1 disable
    #     # 	output "Some Company ASDF 4242" mode 1600x900 position 0,0
    #     # }

    #     # profile {
    #     # 	output LVDS-1 enable scale 2
    #     # }

    #     undocked = {
    #       outputs = [{
    #         criteria = "eDP-1";
    #         scale = 1.0;
    #         status = "enable";
    #       }];
    #     };

    #     rnl = {
    #       outputs = [
    #         {
    #           criteria = "Iiyama North America PL3293UH 1213432400052";
    #           position = "0,0";
    #           scale = 1.25;
    #           # Current mode: 3840x2160 @ 59.997 Hz
    #           # Position: 1920,0
    #           # Scale factor: 1.000000
    #           # Scale filter: nearest
    #           # Subpixel hinting: unknown
    #           # Transform: normal
    #           # Workspace: 5
    #           # Max render time: off
    #           # Adaptive sync: disabled
    #           # Available modes:
    #         }
    #         {
    #           criteria = "eDP-1";
    #           position = "576,1728";
    #         }
    #       ];
    #     };
    #   };
    # };

    wayland.windowManager.sway.config = rec {
      # TODO
      # output = { "*".bg = "~/Pictures/wallpaper.jpg fill"; };

      workspaceOutputAssign = [{
        workspace = "9";
        output = "DP-1";
      }];
    };
  };

  system.stateVersion = "24.05";
}
