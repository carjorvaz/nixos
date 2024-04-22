{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ../profiles/nixos/base.nix
    ../profiles/nixos/bluetooth.nix
    ../profiles/nixos/bootloader/systemd-boot.nix
    ../profiles/nixos/cpu/intel.nix
    ../profiles/nixos/gpu/intel.nix
    ../profiles/nixos/fingerprint.nix
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

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "nvme" "usb_storage" "sd_mod" "rtsx_pci_sdmmc" ];

  networking = {
    useDHCP = true;
    hostName = "trajanus";
    hostId = "d7ba56e3";
  };

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

    wayland.windowManager.sway.config = rec {
      # output = {
      #   "eDP-1".scale = "1.5";
      # };
    };
  };

  system.stateVersion = "23.11";
}
