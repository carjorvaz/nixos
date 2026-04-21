{ config, pkgs, ... }:

let
  domain = "searx.vaz.ovh";
  secretFile = "/run/searx-secret";
in
{
  services = {
    nginx = {
      tailscaleAuth = {
        enable = true;
        virtualHosts = [ domain ];
      };

      virtualHosts.${domain} = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/".proxyPass = "http://127.0.0.1:${toString config.services.searx.settings.server.port}";
      };
    };

    searx = {
      enable = true;
      environmentFile = secretFile;

      settings = {
        server.port = 8888;
        server.bind_address = "127.0.0.1";
        server.secret_key = "$SEARX_SECRET_KEY";

        search.formats = [
          "html"
          "json"
        ];
      };
    };

    homer.entries = [
      {
        name = "SearXNG";
        subtitle = "Search";
        url = "https://${domain}";
        logo = "/assets/icons/searxng.svg";
        group = "productivity";
      }
    ];
  };

  # Generate a fresh SearXNG secret at boot; CSRF tokens are session-scoped,
  # so there is no need to persist this across restarts.
  systemd.services.searx-gen-secret = {
    description = "Generate SearXNG secret key";
    wantedBy = [ "searx-init.service" ];
    before = [ "searx-init.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "searx-gen-secret" ''
        printf 'SEARX_SECRET_KEY=%s\n' "$(${pkgs.openssl}/bin/openssl rand -hex 32)" > ${secretFile}
        chmod 400 ${secretFile}
      '';
    };
  };
}
