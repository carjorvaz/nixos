{
  disks ? [ "/dev/sda" ],
  lib,
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

      options = {
        ashift = "12";
        autotrim = "on";
      };

      rootFsOptions = {
        acltype = "posixacl";
        atime = "off";
        canmount = "off";
        compression = "lz4";
        dnodesize = "auto";
        normalization = "formD";
        xattr = "sa";
        mountpoint = "none";
        # "com.sun:auto-snapshot" = "false"; # TODO? sanoid?
      };

      postCreateHook = lib.mkDefault "zfs snapshot zroot@blank"; # TODO delete after everything is migrated to zfs impermanence

      datasets = {
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

  # Disko takes care of filesystem configuration but this
  # is needed because of the impermanence module.
  fileSystems."/persist".neededForBoot = true;

  environment.persistence."/persist" = {
    hideMounts = true;
    files = [ "/etc/machine-id" ];
    directories = [
      "/var/db/sudo/lectured"
      "/var/lib/nixos"
      "/var/log/journal"
    ];
  };
}
