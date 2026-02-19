# Conflicts: podman.nix (both set oci-containers.backend)
{ ... }:

{
  virtualisation = {
    docker = {
      enable = true;
      autoPrune.enable = true;
    };

    oci-containers.backend = "docker";
  };
}
