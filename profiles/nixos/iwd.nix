{ pkgs, ... }:

{
  # STATE: connecting to eduroam:
  # - https://www.math.cmu.edu/~gautam/sj/blog/20211025-eduroam-iwd.html
  # - https://wiki.nixos.org/wiki/Iwd#Eduroam_(WPA2_Enterprise)_network
  networking = {
    networkmanager = {
      enable = true;
      wifi.backend = "iwd";
    };

    wireless.iwd = {
      enable = true;

      settings.General = {
        AddressRandomization = "network";
        AddressRandomizationRange = "nic";
      };
    };
  };

  environment.persistence."/persist".directories = [ "/var/lib/iwd" ];
}
