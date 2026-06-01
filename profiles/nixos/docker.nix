# Conflicts: podman.nix (both set oci-containers.backend)
_:

{
  virtualisation = {
    docker = {
      enable = true;
      autoPrune.enable = true;
    };

    oci-containers.backend = "docker";
  };
}
