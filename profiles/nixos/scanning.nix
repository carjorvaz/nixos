{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Enable network scanning.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };

  hardware.sane = {
    enable = true;
    extraBackends = [ pkgs.sane-airscan ];
  };

  users.users.cjv.extraGroups = [
    "scanner"
    "lp"
  ];
}
