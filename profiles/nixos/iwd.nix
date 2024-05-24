{ config, lib, pkgs, ... }:

{
  # STATE: connecting to eduroam https://www.math.cmu.edu/~gautam/sj/blog/20211025-eduroam-iwd.html
  networking.wireless.iwd = {
    enable = true;

    # Conflicts with dhcpcd
    settings.General.EnableNetworkConfiguration = true;
  };

  environment.persistence."/persist".directories = [ "/var/lib/iwd" ];
}
