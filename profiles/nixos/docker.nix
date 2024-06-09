{
  config,
  lib,
  pkgs,
  ...
}:

{
  virtualisation = {
    docker = {
      enable = true;
      autoPrune.enable = true;
    };

    oci-containers.backend = "docker";
  };
}
