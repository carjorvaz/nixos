{
  pkgs,
  ...
}:

let
  excludeFile = ./mac-file-backup.exclude;

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
    name = "mac-file-backup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
      pkgs.rsync
    ];
    text = ''
      set -eu

      remote_host="pius"
      remote_root="/mnt/mac-backups/mac"
      cache_dir="$HOME/Library/Caches/mac-file-backup"
      lock_dir="$cache_dir/lock"

      mkdir -p "$cache_dir"

      if ! mkdir "$lock_dir" 2>/dev/null; then
        echo "mac-file-backup: another run is already active"
        exit 0
      fi

      cleanup() {
        rmdir "$lock_dir"
      }
      trap cleanup EXIT

      if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" true; then
        echo "mac-file-backup: $remote_host is unreachable, skipping"
        exit 0
      fi

      ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_host" \
        "install -d -m 0750 '$remote_root'"

      for rel in ${builtins.concatStringsSep " " sources}; do
        src="$HOME/$rel"

        if [ ! -e "$src" ]; then
          echo "mac-file-backup: skipping missing $rel"
          continue
        fi

        echo "mac-file-backup: syncing $rel"

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
  launchd.user.agents.mac-file-backup = {
    environment.HOME = "/Users/cjv";
    path = [ pkgs.coreutils ];
    command = "${backupScript}/bin/mac-file-backup";
    serviceConfig = {
      ProcessType = "Background";
      RunAtLoad = true;
      StartInterval = 21600;
      WorkingDirectory = "/Users/cjv";
      StandardOutPath = "/Users/cjv/Library/Logs/mac-file-backup.log";
      StandardErrorPath = "/Users/cjv/Library/Logs/mac-file-backup.log";
    };
  };
}
