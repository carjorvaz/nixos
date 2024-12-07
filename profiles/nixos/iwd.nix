{
  config,
  lib,
  pkgs,
  ...
}:

{
  # STATE: connecting to eduroam:
  # - https://www.math.cmu.edu/~gautam/sj/blog/20211025-eduroam-iwd.html
  # - https://wiki.nixos.org/wiki/Iwd#Eduroam_(WPA2_Enterprise)_network
  networking.wireless.iwd = {
    enable = true;

    # Conflicts with dhcpcd
    settings.General.EnableNetworkConfiguration = true;
  };

  networking.useDHCP = false;

  environment.persistence."/persist".directories = [ "/var/lib/iwd" ];
}
