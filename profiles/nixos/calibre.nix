{ config, lib, pkgs, ... }:

let
  domain = "calibre.vaz.ovh";
  expectedTailnet = "tail01b8d.ts.net";
  port = 8083;
  library = "/persist/media/books";
  # CWA consumes files placed here and removes them after processing.
  ingest = "/persist/media/downloads/books-ingest";
  image = "crocodilestick/calibre-web-automated:v4.0.6";
  calibreWebUid = 982;
  calibreWebGid = 997;
  mediaGid = 973;
  fixSharedMediaPerms = pkgs.writeShellApplication {
    name = "calibre-web-fix-shared-media-perms";
    runtimeInputs = with pkgs; [
      coreutils
      docker
      findutils
    ];
    text = ''
      for _ in $(seq 1 90); do
        status="$(${pkgs.docker}/bin/docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' calibre-web-automated 2>/dev/null || true)"
        if [ "$status" = "healthy" ]; then
          break
        fi
        sleep 2
      done

      chgrp -R media ${library}
      chmod -R g+rwX ${library}
      find ${library} -type d -exec chmod g+s {} +

      chgrp media ${ingest}
      chmod 2775 ${ingest}
    '';
  };
  configureTailnetLogin = pkgs.writeShellApplication {
    name = "calibre-web-configure-tailnet-login";
    runtimeInputs = with pkgs; [ sqlite ];
    text = ''
      db=/var/lib/calibre-web/app.db
      if [ ! -f "$db" ]; then
        exit 0
      fi

      sqlite3 "$db" "
        UPDATE settings
        SET
          config_reverse_proxy_login_header_name = 'X-CWA-User',
          config_allow_reverse_proxy_header_login = 1,
          config_reverse_proxy_auto_create_users = 0;
      "
    '';
  };
in
{
  services = {
    nginx = {
      tailscaleAuth = {
        enable = true;
        inherit expectedTailnet;
        virtualHosts = [ domain ];
      };

      virtualHosts.${domain} = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/".proxyPass = "http://127.0.0.1:${toString port}";
        locations."/".extraConfig = ''
          # This host is tailnet-only, so Tailscale auth can map directly to the
          # existing personal CWA account without an extra app login.
          proxy_set_header X-CWA-User cjv;
        '';
      };
    };

    homer.entries = [
      {
        name = "Calibre";
        subtitle = "E-books";
        url = "https://${domain}";
        logo = "/assets/icons/calibre-web.svg";
        group = "media";
      }
    ];
  };

  users.groups = {
    calibre-web.gid = lib.mkDefault calibreWebGid;
    media.gid = lib.mkDefault mediaGid;
  };

  users.users.calibre-web = {
    isSystemUser = true;
    uid = lib.mkDefault calibreWebUid;
    group = "calibre-web";
    extraGroups = [ "media" ];
  };

  systemd.tmpfiles.rules = [
    "d /persist/media/downloads/books-ingest 2775 root media -"
  ];

  virtualisation.oci-containers.containers.calibre-web-automated = {
    autoStart = true;
    inherit image;
    ports = [ "127.0.0.1:${toString port}:${toString port}" ];
    environment = {
      PUID = toString calibreWebUid;
      PGID = toString calibreWebGid;
      TZ = config.time.timeZone;
      CWA_PORT_OVERRIDE = toString port;
    };
    volumes = [
      "/var/lib/calibre-web:/config"
      "${ingest}:/cwa-book-ingest"
      "${library}:/calibre-library"
    ];
    extraOptions = [ "--group-add=${toString mediaGid}" ];
  };

  systemd.services."docker-calibre-web-automated" = {
    preStart = lib.mkBefore ''
      ${configureTailnetLogin}/bin/calibre-web-configure-tailnet-login
    '';

    serviceConfig.ExecStartPost = lib.mkAfter [
      "${fixSharedMediaPerms}/bin/calibre-web-fix-shared-media-perms"
    ];
  };

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/calibre-web"; user = "calibre-web"; group = "calibre-web"; }
  ];
}
