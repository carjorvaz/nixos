{ config, lib, pkgs, ... }:

{
  imports = [ ./common.nix ];

  boot.plymouth.enable = lib.mkDefault true;
  boot.initrd.systemd.enable = lib.mkDefault true;

  boot.loader.systemd-boot = {
    enable = true;
    editor = false;
    configurationLimit = 10;
  };
}
