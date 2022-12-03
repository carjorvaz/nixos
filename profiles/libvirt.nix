{ config, lib, pkgs, ... }:

{
  virtualisation = {
    libvirtd.enable = true;
    spiceUSBRedirection.enable = true;
  };

  users.users.cjv.extraGroups = [ "libvirtd" ];
}
