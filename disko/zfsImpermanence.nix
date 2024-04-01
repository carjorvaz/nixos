# TODO migrate everything running with root as tmpfs to this and merge this with base.nix
{ lib, ... }: {
  disko.devices.zpool.zroot = {
    postCreateHook = "zfs snapshot zroot/local/root@blank";
    datasets."local/root" = {
      type = "zfs_fs";
      mountpoint = "/";
    };
  };

  boot = {
    initrd = {
      systemd.enable = false;
      postDeviceCommands = lib.mkAfter ''
        zfs rollback -r zroot/local/root@blank
      '';
    };

    plymouth.enable = false;
  };
}
