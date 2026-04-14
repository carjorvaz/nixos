{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.services.zfsBackup.source;

  # Script to check if current network is metered
  isMeteredScript = pkgs.writeShellScript "is-metered" ''
    # Check if any active connection is metered
    # nmcli returns "yes" for metered, "no" or "unknown" for unmetered
    ${pkgs.networkmanager}/bin/nmcli -t -f GENERAL.METERED device show 2>/dev/null | grep -q ":yes"
    if [ $? -eq 0 ]; then
      echo "Skipping backup: network is metered"
      exit 1
    fi
    exit 0
  '';
in
{
  imports = [
    "${self}/profiles/nixos/zfs/sanoid.nix"
  ];

  options.services.zfsBackup.source = {
    enable = lib.mkEnableOption "Enable ZFS backup source (snapshots + replication)";

    snapshotMode = lib.mkOption {
      type = lib.types.enum [
        "ephemeral"
        "existing"
      ];
      default = "ephemeral";
      description = ''
        How syncoid chooses snapshots to replicate.

        - `ephemeral`: create semi-ephemeral `syncoid_*` snapshots during each run.
        - `existing`: replicate snapshots that already exist on the source
          (for example, sanoid `autosnap_*` snapshots).
      '';
    };

    datasets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          target = lib.mkOption {
            type = lib.types.str;
            description = "Target in the format user@host:pool/dataset/hostname";
            example = "syncoid@pius:zsafe/backups/trajanus";
          };

          recursive = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether to recursively snapshot and replicate child datasets";
          };

          sendOptions = lib.mkOption {
            type = lib.types.str;
            default = "w";
            description = "ZFS send options (default 'w' for raw send to preserve encryption)";
          };

          recvOptions = lib.mkOption {
            type = lib.types.str;
            default = "-o canmount=noauto";
            description = "ZFS receive options (default sets canmount=noauto to avoid mount permission issues)";
          };
        };
      });
      default = {};
      description = "Datasets to snapshot and replicate";
      example = {
        "zroot/safe" = {
          target = "syncoid@pius:zsafe/backups/trajanus";
          recursive = true;
        };
      };
    };

    targetHosts = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Map of hostname to SSH public key for declarative known_hosts";
      example = {
        "pius" = "ssh-ed25519 AAAA...";
      };
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "How often to run syncoid replication";
    };

    includeSnapshots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Regular expressions passed to `syncoid --include-snaps`.
        When empty, syncoid may use any source snapshot name.
      '';
      example = [ "^autosnap_.*_(hourly|daily|weekly|monthly|yearly)$" ];
    };

    excludeSnapshots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Regular expressions passed to `syncoid --exclude-snaps`.
        Useful for omitting short-lived source snapshots such as `frequently`.
      '';
      example = [ "^autosnap_.*_frequently$" ];
    };

    sshKey = lib.mkOption {
      type = lib.types.path;
      description = "Path to SSH private key for authenticating to backup targets (e.g., agenix secret path)";
      example = "config.age.secrets.syncoidSshKey.path";
    };

    noResume = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Disable resumable send/receive. Recommended for roaming devices.
        When enabled, interrupted syncs restart from the last common snapshot
        instead of trying to resume, avoiding stale resume token errors.
        See: https://github.com/jimsalterjrs/sanoid/issues/304
      '';
    };

    noStream = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Use `syncoid --no-stream`, which updates the target to the newest
        matching source snapshot without sending intermediate snapshots as part
        of the same replication run.

        This is often a good fit for roaming devices with unreliable links, but
        it can skip snapshot names between runs. If you need the target to see
        every source snapshot, leave this disabled.
      '';
    };

    createBookmark = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Create a bookmark for the newest replicated snapshot after a successful run.
        This is only valid with `snapshotMode = "existing"` and is especially useful
        for irregular replication from roaming machines whose older source snapshots
        may be pruned before the next backup.
      '';
    };

    keepSyncSnapshots = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Keep `syncoid_*` snapshots created during replication instead of letting
        syncoid prune older ones. Only applies to `snapshotMode = "ephemeral"`.
      '';
    };

    skipOnMetered = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Skip backup when connected to a metered network (e.g., mobile tethering).
        Uses NetworkManager to detect metered connections.
        Mark connections as metered with: nmcli connection modify "ConnectionName" connection.metered yes
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = (!cfg.createBookmark) || cfg.snapshotMode == "existing";
        message = "services.zfsBackup.source.createBookmark requires snapshotMode = \"existing\".";
      }
      {
        assertion = (!cfg.keepSyncSnapshots) || cfg.snapshotMode == "ephemeral";
        message = "services.zfsBackup.source.keepSyncSnapshots only applies to snapshotMode = \"ephemeral\".";
      }
    ];

    # Enable sanoid snapshots for all configured datasets
    services.sanoid.datasets = lib.mapAttrs (_dataset: _opts: {
      use_template = [ "default" ];
      recursive = true;
    }) cfg.datasets;

    # Declarative known_hosts for backup targets
    programs.ssh.knownHosts = lib.mapAttrs (host: publicKey: {
      inherit publicKey;
    }) cfg.targetHosts;

    # Enable syncoid replication
    services.syncoid = {
      enable = true;
      interval = cfg.interval;
      sshKey = cfg.sshKey;
      commonArgs =
        lib.optionals (cfg.snapshotMode == "existing") [ "--no-sync-snap" ]
        ++ lib.optionals cfg.createBookmark [ "--create-bookmark" ]
        ++ lib.optionals cfg.keepSyncSnapshots [ "--keep-sync-snap" ]
        ++ lib.optionals cfg.noResume [ "--no-resume" ]
        ++ lib.optionals cfg.noStream [ "--no-stream" ]
        ++ builtins.concatMap (pattern: [ "--include-snaps=${pattern}" ]) cfg.includeSnapshots
        ++ builtins.concatMap (pattern: [ "--exclude-snaps=${pattern}" ]) cfg.excludeSnapshots;

      commands = lib.mapAttrs (dataset: opts: {
        target = opts.target;
        recursive = opts.recursive;
        sendOptions = opts.sendOptions;
        recvOptions = opts.recvOptions;
      }) cfg.datasets;
    };

    # Add metered network check to syncoid services
    systemd.services = lib.mkIf cfg.skipOnMetered (
      lib.mapAttrs' (dataset: _opts:
        let
          serviceName = "syncoid-${builtins.replaceStrings [ "/" ] [ "-" ] dataset}";
        in
        lib.nameValuePair serviceName {
          serviceConfig.ExecCondition = "+" + isMeteredScript;  # + runs as root, avoids CHDIR issues
        }
      ) cfg.datasets
    );
  };
}
