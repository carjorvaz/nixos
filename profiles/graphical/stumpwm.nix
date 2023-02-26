{ config, lib, pkgs, ... }:

{
  services.xserver.displayManager.startx.enable = true;

  environment.systemPackages = with pkgs; [ sbcl rlwrap ];

  home-manager.users.cjv = {
    services = {
      redshift = {
        enable = true;
        latitude = 38.7;
        longitude = -9.14;
        temperature = {
          day = 6500;
          night = 2000;
        };
      };
    };
  };
}
