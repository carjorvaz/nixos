{ config, lib, pkgs, ... }:

{
    services.fail2ban = {
      enable = true;
      maxretry = 5;
      bantime-increment = {
        enable = true;
        rndtime = "5min";
        maxtime = "24h";
      };
    };
}
