{ config, lib, pkgs, ... }:

{
  virtualisation = {
    libvirtd.enable = true;
    spiceUSBRedirection.enable = true;
  };

  programs.virt-manager.enable = true;
  users.users.cjv.extraGroups = [ "libvirtd" ];
}
