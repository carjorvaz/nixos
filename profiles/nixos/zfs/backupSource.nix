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
        Send each snapshot individually instead of as a continuous stream.
        Highly recommended for roaming devices with unreliable connections.

        With streaming (default): if transfer fails mid-way, all progress is lost.
        With --no-stream: each snapshot that completes is preserved on target,
        so interrupted transfers resume from the last successful snapshot.

        Trade-off: slightly less efficient, but much more robust against interruptions.
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
        lib.optionals cfg.noResume [ "--no-resume" ]
        ++ lib.optionals cfg.noStream [ "--no-stream" ];

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
