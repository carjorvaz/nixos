{
  config,
  self,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.cjv.storage.pius.darwinFileBackups;
  # Keep the existing dataset and mountpoint names to avoid moving live backup
  # data around on pius just for nomenclature.
  dataset = cfg.dataset;
  mountpoint = cfg.mountpoint;
  hosts = cfg.hosts;
in
{
  options.cjv.storage.pius.darwinFileBackups = {
    dataset = lib.mkOption {
      type = lib.types.str;
      default = "zsafe/mac-backups";
      description = "ZFS dataset for plain-file Darwin backups.";
    };

    mountpoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/mac-backups";
      description = "Mountpoint for plain-file Darwin backups.";
    };

    hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "air" ];
      description = "Darwin host directories to ensure under the backup mountpoint.";
    };
  };

  imports = [
    "${self}/profiles/nixos/zfs/sanoid.nix"
  ];

  config = {
    services.sanoid = {
      templates.darwinFiles = {
        frequently = 0;
        hourly = 48;
        daily = 30;
        weekly = 12;
        monthly = 24;
        yearly = 5;
        autosnap = true;
        autoprune = true;
      };

      datasets.${dataset} = {
        use_template = [ "darwinFiles" ];
        recursive = true;
      };
    };

    systemd.services.darwin-file-backups-dataset = {
      description = "Create the ZFS dataset for plain-file Darwin backups";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if ! ${pkgs.zfs}/bin/zfs list -H -o name ${dataset} >/dev/null 2>&1; then
          ${pkgs.zfs}/bin/zfs create -o mountpoint=${mountpoint} ${dataset}
        fi

        ${pkgs.zfs}/bin/zfs mount ${dataset} >/dev/null 2>&1 || true
        ${lib.concatMapStringsSep "\n" (
          host: "${pkgs.coreutils}/bin/install -d -m 0750 ${mountpoint}/${host}"
        ) hosts}
      '';
    };

    systemd.tmpfiles.rules = [
      "d ${mountpoint} 0750 root root -"
    ];
  };
}
