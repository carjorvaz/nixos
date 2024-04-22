{ self, config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/bluetooth.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/gpu/intel.nix"
    "${self}/profiles/nixos/fingerprint.nix"
    "${self}/profiles/nixos/iwctl.nix"
    "${self}/profiles/nixos/dns/dnscrypt.nix"
    "${self}/profiles/nixos/laptop.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/cjv.nix"
    "${self}/profiles/nixos/docker.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/graphical/sway.nix"
    "${self}/profiles/nixos/qmk.nix"
    "${self}/profiles/nixos/ssh.nix"

    # STATE: sudo tailscale up
    "${self}/profiles/nixos/tailscale.nix"
  ];

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "nvme" "usb_storage" "sd_mod" "rtsx_pci_sdmmc" ];

  networking = {
    useDHCP = true;
    hostName = "trajanus";
    hostId = "d7ba56e3";
  };

  services.throttled.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  home-manager.users.cjv = {
    programs.i3status-rust.bars.top.blocks = [
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

    services.kanshi = {
      enable = true;

      profiles = {

        # Configuration file
        # Each output profile is delimited by brackets. It contains several output directives (whose syntax is similar to sway-output(5)). A profile will be enabled if all of the listed outputs are connected.

        # profile {
        # 	output LVDS-1 disable
        # 	output "Some Company ASDF 4242" mode 1600x900 position 0,0
        # }

        # profile {
        # 	output LVDS-1 enable scale 2
        # }

        undocked = {
          outputs = [{
            criteria = "eDP-1";
            scale = 1.0;
            status = "enable";
          }];
        };

        rnl = {
          outputs = [
            {
              criteria = "Iiyama North America PL3293UH 1213432400052";
              position = "0,0";
              scale = 1.25;
              # Current mode: 3840x2160 @ 59.997 Hz
              # Position: 1920,0
              # Scale factor: 1.000000
              # Scale filter: nearest
              # Subpixel hinting: unknown
              # Transform: normal
              # Workspace: 5
              # Max render time: off
              # Adaptive sync: disabled
              # Available modes:
            }
            {
              criteria = "eDP-1";
              status = "disable";
            }
          ];
        };
      };
    };
  };

  system.stateVersion = "23.11";
}
