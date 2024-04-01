{ config, lib, pkgs, ... }:

{
  networking = {
    # STATE: connecting to eduroam https://www.math.cmu.edu/~gautam/sj/blog/20211025-eduroam-iwd.html
    wireless.iwd.enable = true;
    settings.General.EnableNetworkConfiguration = true;
  };

  environment.persistence."/persist".directories = [ "/var/lib/iwd" ];
}
