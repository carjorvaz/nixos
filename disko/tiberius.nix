{
  disks,
  ...
}:
{
  # Split layout: sda carries the boot pool and OS datasets, sdb is a whole
  # second pool for model/blob storage. No mirror — the rig is reproducible
  # from this flake and 224G usable was too tight for model weights.
  cjv.impermanence.zfsBootRollback.rootDataset = "zroot/local/root";

  disko.devices = {
    disk = {
      sda = {
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

      sdb = {
        device = builtins.elemAt disks 1;
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            data = {
              size = "100%";
              content = {
                type = "zfs";
                pool = "zdata";
              };
            };
          };
        };
      };
    };

    zpool = {
      zroot = {
        type = "zpool";
        postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^zroot/local/root@blank$' || zfs snapshot zroot/local/root@blank";

        options = {
          ashift = "12";
          autotrim = "on";
        };

        rootFsOptions = {
          acltype = "posixacl";
          # systemd-tmpfiles age cleanup requires STATX_ATIME. With ZFS atime=off,
          # systemd 260 reports statx(...): Protocol driver not attached for /tmp.
          # Keep atime available while relatime limits normal access-time churn.
          atime = "on";
          canmount = "off";
          compression = "zstd";
          dnodesize = "auto";
          normalization = "formD";
          xattr = "sa";
          mountpoint = "none";
          relatime = "on";
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

      zdata = {
        type = "zpool";
        options = {
          ashift = "12";
          autotrim = "on";
        };

        rootFsOptions = {
          acltype = "posixacl";
          atime = "on";
          canmount = "off";
          compression = "zstd";
          dnodesize = "auto";
          normalization = "formD";
          xattr = "sa";
          mountpoint = "none";
          relatime = "on";
        };

        datasets = {
          "local/data" = {
            type = "zfs_fs";
            mountpoint = "/data";
          };
          "local/reserved" = {
            type = "zfs_fs";
            options = {
              mountpoint = "none";
              refreservation = "10G";
            };
          };
        };
      };
    };
  };
}
