{ config, lib, pkgs, ... }:

{
  boot.supportedFilesystems = [ "zfs" ];

  services.zfs = {
    trim.enable = true;
    autoScrub.enable = true;
  };
}
