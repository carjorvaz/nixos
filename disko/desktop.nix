{ ... }:
{
  disko.devices.zpool.zroot.datasets."safe/home" = {
    type = "zfs_fs";
    mountpoint = "/home";
  };
}
