{
  self,
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  package = inputs.telegram-mirror-rs.packages.${pkgs.stdenv.hostPlatform.system}.default;
  sessionDir = "/var/lib/telegram-mirror/session";
  defaultArchiveDir = "/persist/telegram-mirror/archive";

  authCommand = pkgs.writeShellApplication {
    name = "telegram-mirror-auth";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
    ];
    text = ''
      set -eu
      # shellcheck source=/dev/null
      set -a
      . ${config.age.secrets.telegramMirrorEnv.path}
      set +a

      exec runuser -u telegram-mirror -- env \
        TELEGRAM_MIRROR_API_ID="$TELEGRAM_MIRROR_API_ID" \
        TELEGRAM_MIRROR_API_HASH="$TELEGRAM_MIRROR_API_HASH" \
        ${lib.getExe package} \
          --session-dir ${lib.escapeShellArg sessionDir} \
          auth
    '';
  };
in
{
  age.secrets.telegramMirrorEnv = {
    file = "${self}/secrets/telegramMirrorEnv.age";
    owner = "telegram-mirror";
    group = "telegram-mirror";
    mode = "0400";
  };

  users = {
    groups.telegram-mirror = { };
    users.telegram-mirror = {
      isSystemUser = true;
      group = "telegram-mirror";
      home = "/var/lib/telegram-mirror";
    };
  };

  environment.systemPackages = [
    package
    authCommand
  ];

  systemd.tmpfiles.rules = [
    "d /persist/telegram-mirror 0700 telegram-mirror telegram-mirror -"
    "d ${defaultArchiveDir} 0700 telegram-mirror telegram-mirror -"
  ];

  systemd.services.telegram-mirror = {
    description = "Telegram channel preservation mirror";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    startAt = null;
    serviceConfig = {
      Type = "oneshot";
      User = "telegram-mirror";
      Group = "telegram-mirror";
      EnvironmentFile = config.age.secrets.telegramMirrorEnv.path;
      StateDirectory = "telegram-mirror";
      StateDirectoryMode = "0700";
      WorkingDirectory = "/persist/telegram-mirror";
      TimeoutStartSec = "infinity";
      Nice = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
    };
    script = ''
      set -eu
      : "''${TELEGRAM_MIRROR_PEER:?set TELEGRAM_MIRROR_PEER in telegramMirrorEnv.age}"
      out="''${TELEGRAM_MIRROR_OUT:-${defaultArchiveDir}}"
      pause_ms="''${TELEGRAM_MIRROR_PAUSE_MS:-250}"
      mkdir -p "$out"

      exec ${lib.getExe package} \
        --session-dir ${lib.escapeShellArg sessionDir} \
        sync \
        --peer "$TELEGRAM_MIRROR_PEER" \
        --out "$out" \
        --pause-ms "$pause_ms"
    '';
  };

  systemd.timers.telegram-mirror = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "20m";
      OnUnitInactiveSec = "1h";
      Persistent = true;
      RandomizedDelaySec = "10m";
      Unit = "telegram-mirror.service";
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/telegram-mirror";
      user = "telegram-mirror";
      group = "telegram-mirror";
      mode = "0700";
    }
  ];
}
