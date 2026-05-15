{ config, pkgs, ... }:

let
  domain = "uttt.vaz.one";
  port = 4242;
  stateDir = "/var/lib/ultimate-tic-tac-toe";
  runService = pkgs.writeShellScript "run-ultimate-tic-tac-toe" ''
    set -euo pipefail

    state_directory="''${STATE_DIRECTORY:-${stateDir}}"
    install -m 0700 -d "$state_directory" "$state_directory/cache"

    export HOME="$state_directory"
    export XDG_CACHE_HOME="$state_directory/cache"

    if [ ! -s "$state_directory/session-secret" ]; then
      umask 077
      ${pkgs.openssl}/bin/openssl rand -hex 32 > "$state_directory/session-secret"
    fi

    export PORT="${toString port}"
    export SESSION_SECRET="$(cat "$state_directory/session-secret")"
    exec ${pkgs.ultimate-tic-tac-toe}/bin/ultimate-tic-tac-toe
  '';
in
{
  services.nginx.virtualHosts.${domain} = {
    forceSSL = true;
    useACMEHost = "vaz.one";

    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
    };
  };

  systemd.services.ultimate-tic-tac-toe = {
    description = "Ultimate Tic Tac Toe web app";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = runService;
      User = "ultimate-tic-tac-toe";
      Group = "ultimate-tic-tac-toe";
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "ultimate-tic-tac-toe";
      StateDirectoryMode = "0700";

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ stateDir ];
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
      CapabilityBoundingSet = "";
      LockPersonality = true;
      RestrictRealtime = true;
      SystemCallArchitectures = "native";
    };
  };

  users.users.ultimate-tic-tac-toe = {
    group = "ultimate-tic-tac-toe";
    isSystemUser = true;
  };
  users.groups.ultimate-tic-tac-toe = { };

  environment.persistence."/persist".directories = [
    {
      directory = stateDir;
      user = "ultimate-tic-tac-toe";
      group = "ultimate-tic-tac-toe";
      mode = "0700";
    }
  ];
}
