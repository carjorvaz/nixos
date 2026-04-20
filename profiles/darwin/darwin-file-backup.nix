{
  config,
  pkgs,
  lib,
  ...
}:

let
  # Keep the existing server-side mountpoint layout to avoid churn on pius.
  backupRoot = "/mnt/mac-backups";
  excludeFile = ./darwin-file-backup.exclude;
  hostName = config.networking.hostName;
  jobName = "${hostName}-file-backup";
  remoteRoot = "${backupRoot}/${hostName}";

  sources = [
    "Desktop"
    "Documents"
    "Downloads"
    "Movies"
    "Music"
    "Pictures"
    "agents"
    "claude"
    "org"
  ];

  backupScript = pkgs.writeShellApplication {
    name = jobName;
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
      pkgs.rsync
    ];
    text = ''
      set -eu

      remote_host="pius"
      remote_root=${lib.escapeShellArg remoteRoot}
      cache_dir="$HOME/Library/Caches/${jobName}"
      lock_dir="$cache_dir/lock"

      mkdir -p "$cache_dir"

      if ! mkdir "$lock_dir" 2>/dev/null; then
        echo "${jobName}: another run is already active"
        exit 0
      fi

      cleanup() {
        rmdir "$lock_dir"
      }
      trap cleanup EXIT

      if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" true; then
        echo "${jobName}: $remote_host is unreachable, skipping"
        exit 0
      fi

      ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" \
        "install -d -m 0750 '$remote_root'"

      for rel in ${builtins.concatStringsSep " " sources}; do
        src="$HOME/$rel"

        if [ ! -e "$src" ]; then
          echo "${jobName}: skipping missing $rel"
          continue
        fi

        echo "${jobName}: syncing $rel"

        rsync \
          --archive \
          --delete \
          --exclude-from='${excludeFile}' \
          --human-readable \
          --itemize-changes \
          --mkpath \
          --partial \
          --protect-args \
          -e "ssh -o BatchMode=yes -o ConnectTimeout=10" \
          "$src/" \
          "$remote_host:$remote_root/$rel/"
      done
    '';
  };
in
{
  launchd.user.agents."${jobName}" = {
    environment.HOME = "/Users/cjv";
    path = [ pkgs.coreutils ];
    command = "${backupScript}/bin/${jobName}";
    serviceConfig = {
      ProcessType = "Background";
      RunAtLoad = true;
      StartInterval = 21600;
      WorkingDirectory = "/Users/cjv";
      StandardOutPath = "/Users/cjv/Library/Logs/${jobName}.log";
      StandardErrorPath = "/Users/cjv/Library/Logs/${jobName}.log";
    };
  };
}
