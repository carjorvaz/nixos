{ config, lib, pkgs, ... }:

{
 # Not needed with root on tmpfs.
  virtualisation.docker.storageDriver = "zfs";
}
