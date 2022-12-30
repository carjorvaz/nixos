{ config, lib, pkgs, ... }:

{
  virtualisation = {
    docker = {
      enable = true;
      storageDriver = "zfs";
      autoPrune.enable = true;
    };

    oci-containers.backend = "docker";
  };
}
