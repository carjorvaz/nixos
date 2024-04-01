{ config, lib, pkgs, ... }:

{
  # TODO mail reports with zed if msmtp is enabled
  #  nixpkgs.config.packageOverrides = pkgs: {
  #   zfsStable = pkgs.zfsStable.override { enableMail = true; };
  # };

  # services.zfs.zed.enableMail = true;
  # services.zfs.zed.settings = {
  #   ZED_EMAIL_ADDR = [ "carlos+zfs@vaz.one" ];
  #   ZED_NOTIFY_VERBOSE = true;
  # };
}
