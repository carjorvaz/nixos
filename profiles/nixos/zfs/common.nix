{ config, lib, pkgs, ... }:

{
  services.zfs = {
    trim.enable = true;
    autoScrub.enable = true;
  };
}
