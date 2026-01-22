{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.services.zfsBackup.target;
in
{
  imports = [
    "${self}/profiles/nixos/zfs/sanoid.nix"
  ];

  options.services.zfsBackup.target = {
    enable = lib.mkEnableOption "Enable ZFS backup target (receive backups from other hosts)";

    sshPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "SSH public host keys of source machines that can send backups";
      example = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFoo... root@trajanus"
      ];
    };

    dataset = lib.mkOption {
      type = lib.types.str;
      default = "zsafe/backups";
      description = "ZFS dataset where backups will be stored (syncoid user gets permissions on this dataset and descendants)";
    };

    mountpoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/backups";
      description = "Where to mount the backup dataset";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create the backup dataset on first setup:
    #   zfs create -o mountpoint=/mnt/backups zsafe/backups
    #
    # You can manually mount/unmount with:
    #   zfs mount zsafe/backups
    #   zfs unmount zsafe/backups

    # Sanoid on backup target: prune only, with LONGER retention than sources.
    # This ensures source prunes first, syncoid moves to a newer base snapshot,
    # then target prunes the old one. Prevents "invalid backup stream" errors.
    #
    # IMPORTANT: Sanoid will NOT prune a dataset down to zero snapshots.
    # Pruning requires BOTH: (1) snapshot older than retention, AND (2) at least
    # retention+1 snapshots of that type exist. If replication stops, pruning
    # stops once minimums are reached. Discontinued devices keep their snapshots.
    # Reference: https://discourse.practicalzfs.com/t/keeping-a-minimum-number-of-snapshots/1326/4
    #
    # Manual commands:
    #   # Force prune now (respects retention minimums):
    #   sanoid --prune-snapshots --force-prune
    #
    #   # Remove a discontinued host's backups entirely:
    #   zfs destroy -r zsafe/backups/hostname
    services.sanoid = {
      templates.backup = {
        # Retention (~2x source). If replication stops, these become the minimums
        # that sanoid will preserve indefinitely (won't prune below these counts).
        frequently = 0;   # Don't keep frequent snaps on backup (source: 4)
        hourly = 48;      # 2 days worth preserved minimum (source: 24)
        daily = 14;       # 2 weeks worth preserved minimum (source: 7)
        weekly = 8;       # 2 months worth preserved minimum (source: 4)
        monthly = 24;     # 2 years worth preserved minimum (source: 12)
        yearly = 5;       # 5 years worth preserved minimum (source: 2)
        autosnap = false; # Don't create snapshots, only receive replicated ones
        autoprune = true; # Safe: won't prune below retention minimums
      };

      datasets.${cfg.dataset} = {
        use_template = [ "backup" ];
        recursive = true;
      };
    };

    # Create syncoid user for receiving backups
    users.users.syncoid = {
      isSystemUser = true;
      group = "syncoid";
      home = "/var/lib/syncoid";
      createHome = true;
      openssh.authorizedKeys.keys = cfg.sshPublicKeys;
      shell = pkgs.bash;
    };

    users.groups.syncoid = {};

    # Grant ZFS permissions to syncoid user for the backup dataset
    systemd.services.syncoid-permissions = {
      description = "Grant ZFS permissions to syncoid user for receiving backups";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.zfs}/bin/zfs allow -u syncoid canmount,compression,create,destroy,hold,mount,mountpoint,receive,release,send,snapshot,rollback ${cfg.dataset}
        # Allow syncoid to create child mountpoint directories
        chown syncoid:syncoid ${cfg.mountpoint}
      '';
    };

    # Persist syncoid user data
    environment.persistence."/persist".directories = [
      "/var/lib/syncoid"
    ];
  };
}
