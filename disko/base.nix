{
  disks ? [ "/dev/sda" ],
  ...
}:
{
  disko.devices = {
    disk.sda = {
      device = builtins.elemAt disks 0;
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "500M";
            type = "EF00";
            priority = 1;
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };

          root = {
            size = "100%";
            priority = 2;
            content = {
              type = "zfs";
              pool = "zroot";
            };
          };
        };
      };
    };

    zpool.zroot = {
      type = "zpool";
      postCreateHook =
        "zfs list -t snapshot -H -o name | grep -E '^zroot/local/root@blank$' || zfs snapshot zroot/local/root@blank";

      options = {
        ashift = "12";
        autotrim = "on";
      };

      rootFsOptions = {
        acltype = "posixacl";
        atime = "off";
        canmount = "off";
        compression = "zstd";
        dnodesize = "auto";
        normalization = "formD";
        xattr = "sa";
        mountpoint = "none";
        # "com.sun:auto-snapshot" = "false"; # TODO? sanoid?
      };

      datasets = {
        "local/root" = {
          type = "zfs_fs";
          mountpoint = "/";
        };
        "local/nix" = {
          type = "zfs_fs";
          mountpoint = "/nix";
        };
        "local/reserved" = {
          type = "zfs_fs";
          options = {
            mountpoint = "none";
            refreservation = "10G";
          };
        };
        "safe/persist" = {
          type = "zfs_fs";
          mountpoint = "/persist";
        };
      };
    };
  };
}
