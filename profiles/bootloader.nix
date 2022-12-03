{ config, lib, pkgs, ... }:

{
  boot = {
    plymouth.enable = true;
    initrd.systemd.enable = true;

    loader = {
      efi.canTouchEfiVariables = true;

      systemd-boot = {
        enable = true;
        editor = false;
        configurationLimit = 10;
      };
    };
  };
}
