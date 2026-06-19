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
        server = {
          port = 8888;
          bind_address = "127.0.0.1";
          secret_key = "$SEARX_SECRET_KEY";
        };

        search.formats = [
          "html"
          "json"
        ];

        # Kagi-leaderboard-inspired public seed list; keep engine tuning conservative.
        engines = [
          {
            name = "brave";
            engine = "brave";
            shortcut = "br";
            categories = [
              "general"
              "web"
            ];
            brave_category = "search";
            paging = true;
            time_range_support = true;
            weight = 1.15;
          }
          {
            name = "duckduckgo";
            weight = 1.2;
          }
          {
            name = "google";
            weight = 1.05;
          }
          {
            name = "startpage";
            weight = 1.05;
          }
          {
            name = "mojeek";
            disabled = false;
            weight = 0.9;
          }
          {
            name = "wiby";
            disabled = false;
            weight = 0.7;
          }
          {
            name = "wikipedia";
            weight = 1.25;
          }
          {
            name = "github";
            weight = 1.15;
          }
          {
            name = "mdn";
            weight = 1.25;
          }
          {
            name = "stackoverflow";
            weight = 1.15;
          }
          {
            name = "superuser";
            weight = 1.0;
          }
          {
            name = "arch linux wiki";
            weight = 1.1;
          }
          {
            name = "nixos wiki";
            disabled = false;
            weight = 1.15;
          }
        ];

        # Kagi-leaderboard-inspired seed list; hostnames is the main ranking knob.
        hostnames = {
          high_priority = [
            "(.*\\.)?reddit\\.com$"
            "(.*\\.)?wikipedia\\.org$"
            "(.*\\.)?github\\.com$"
            "(.*\\.)?developer\\.mozilla\\.org$"
            "(.*\\.)?docs\\.python\\.org$"
            "(.*\\.)?docs\\.rs$"
            "(.*\\.)?pkg\\.go\\.dev$"
            "(.*\\.)?wiki\\.nixos\\.org$"
            "(.*\\.)?wiki\\.archlinux\\.org$"
            "(.*\\.)?stackoverflow\\.com$"
            "(.*\\.)?superuser\\.com$"
          ];

          low_priority = [
            "(.*\\.)?medium\\.com$"
            "(.*\\.)?quora\\.com$"
            "(.*\\.)?geeksforgeeks\\.org$"
            "(.*\\.)?tutorialspoint\\.com$"
            "(.*\\.)?w3schools\\.com$"
            "(.*\\.)?dev\\.to$"
            "(.*\\.)?hashnode\\.dev$"
          ];

          remove = [
            "(.*\\.)?pinterest\\..*$"
            "(.*\\.)?tiktok\\.com$"
          ];
        };
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
