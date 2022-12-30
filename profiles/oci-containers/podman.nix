{ config, lib, pkgs, ... }:

{
  # Seems to be incompatible with ZFS hosts.
  virtualisation = {
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.dnsname.enable = true;
      extraPackages = [ pkgs.zfs ];
    };

    oci-containers.backend = "podman";
  };
}
