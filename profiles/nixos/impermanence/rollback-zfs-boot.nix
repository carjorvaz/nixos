{
  config,
  lib,
  ...
}:

let
  cfg = config.cjv.impermanence.zfsBootRollback;
  pool =
    if cfg.rootDataset == null then null else builtins.elemAt (lib.splitString "/" cfg.rootDataset) 0;
  snapshot =
    if cfg.rootDataset == null then null
    else if cfg.blankSnapshot != null then cfg.blankSnapshot
    else "${cfg.rootDataset}@blank";
  importService = if pool == null then null else "zfs-import-${pool}.service";
in
{
  options.cjv.impermanence.zfsBootRollback = {
    rootDataset = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "zlocal/root";
      description = ''
        Root dataset to roll back before mounting `/sysroot` in initrd.
        Leave unset to disable boot-time ZFS rollback.
      '';
    };

    blankSnapshot = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "zlocal/root@blank";
      description = ''
        Snapshot to roll back to before mounting the root dataset. Defaults to
        `<rootDataset>@blank`.
      '';
    };
  };

  config = lib.mkIf (cfg.rootDataset != null) {
    boot.initrd.systemd.enable = true;

    boot.initrd.systemd.services.zfs-rollback-root = {
      description = "Roll back ZFS root dataset before mounting /sysroot";
      requiredBy = [ "sysroot.mount" ];
      requires = [ importService ];
      after = [ importService ];
      before = [
        "sysroot.mount"
        "shutdown.target"
      ];
      conflicts = [ "shutdown.target" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo "Rolling back ${cfg.rootDataset} to ${snapshot}"
        /bin/zfs rollback -r ${lib.escapeShellArg snapshot}
      '';
    };
  };
}
