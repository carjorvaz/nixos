{ self, config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/bluetooth.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/gpu/intel.nix"
    "${self}/profiles/nixos/iwctl.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
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
    [ "xhci_pci" "nvme" "usb_storage" "sd_mod" ];

  networking = {
    # Let iwd handle DHCP for Wi-Fi
    useDHCP = false;

    # But use dhcpcd for ethernet
    interfaces.enp0s31f6.useDHCP = true;

    hostName = "trajanus";
    hostId = "d7ba56e3";
  };

  services.thermald.enable = true;

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
        # Each output profile is delimited by brackets.
        # It contains several output directives (whose syntax is similar to sway-output(5)).
        # A profile will be enabled if all of the listed outputs are connected.
        # (wdisplays is useful to get the description criteria)

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
            }
            {
              criteria = "eDP-1";
              status = "disable";
            }
          ];
        };

        home = {
          outputs = [
            {
              criteria = "Dell Inc. DELL U3419W HW796T2";
              position = "0,0";
              scale = 1.0;
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
