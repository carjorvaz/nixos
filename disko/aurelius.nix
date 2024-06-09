{ disks, lib, ... }:
{
  disko.devices = {
    disk =
      let
        mirrorDiskConfig = {
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              data = {
                size = "100%";
                content = {
                  type = "zfs";
                  pool = "zsafe";
                };
              };
            };
          };
        };
      in
      {
        nvme = {
          device = builtins.elemAt disks 0;
          type = "disk";
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                size = "512M";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                };
              };
              root = {
                size = "100%";
                content = {
                  type = "zfs";
                  pool = "zlocal";
                };
              };
            };
          };
        };

        sda = mirrorDiskConfig // {
          device = builtins.elemAt disks 1;
        };

        sdb = mirrorDiskConfig // {
          device = builtins.elemAt disks 2;
        };
      };

    zpool =
      let
        commonPoolConfig = {
          type = "zpool";

          options.ashift = "12";

          rootFsOptions = {
            acltype = "posixacl";
            atime = "off";
            canmount = "off";
            compression = "zstd";
            dnodesize = "auto";
            normalization = "formD";
            xattr = "sa";
            mountpoint = "none";
          };
        };
      in
      {
        zlocal = commonPoolConfig // {
          options.autotrim = "on";

          # Create blank snapshot if it doesn't already exist
          postCreateHook = "zfs list -t snapshot -H -o name | grep -E '^zlocal/root@blank$' || zfs snapshot zlocal/root@blank";

          datasets = {
            "root" = {
              type = "zfs_fs";
              mountpoint = "/";
            };

            "nix" = {
              type = "zfs_fs";
              mountpoint = "/nix";
            };

            "reserved" = {
              type = "zfs_fs";
              options = {
                mountpoint = "none";
                refreservation = "10G";
              };
            };
          };
        };

        zsafe = commonPoolConfig // {
          mode = "mirror";
          datasets = {
            "persist" = {
              type = "zfs_fs";
              mountpoint = "/persist";
            };

            "reserved" = {
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

  # Impermanence
  boot = {
    initrd = {
      systemd.enable = false;
      postDeviceCommands = lib.mkAfter ''
        zfs rollback -r zlocal/root@blank
      '';
    };

    plymouth.enable = false;
  };
}
