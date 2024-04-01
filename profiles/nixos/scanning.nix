{ config, lib, pkgs, ... }:

{
  # Enable network scanning.
  services.avahi = {
    enable = true;
    nssmdns = true;
  };

  hardware.sane = {
    enable = true;
    extraBackends = [ pkgs.sane-airscan ];
  };

  users.users.cjv.extraGroups = [ "scanner" "lp" ];
}
