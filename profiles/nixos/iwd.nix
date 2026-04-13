{ self, ... }:

{
  imports = [
    "${self}/profiles/nixos/networkManager.nix"
  ];

  # STATE: connecting to eduroam:
  # - https://www.math.cmu.edu/~gautam/sj/blog/20211025-eduroam-iwd.html
  # - https://wiki.nixos.org/wiki/Iwd#Eduroam_(WPA2_Enterprise)_network
  networking = {
    networkmanager.wifi.backend = "iwd";

    wireless.iwd = {
      enable = true;

      settings.General = {
        AddressRandomization = "network";
        AddressRandomizationRange = "nic";
        # Regulatory domain for Portugal.
        Country = "PT";
      };
    };
  };

  environment.persistence."/persist".directories = [ "/var/lib/iwd" ];
}
