{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "chat.vaz.ovh";
  user = "open-webui";
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
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString config.services.open-webui.port}";
          proxyWebsockets = true;
        };
      };
    };

    open-webui = {
      enable = true;
      package = pkgs.unstable.open-webui;
      port = 11111;
      host = "127.0.0.1";

      environment = {
        ANONYMIZED_TELEMETRY = "False";
        DO_NOT_TRACK = "True";
        SCARF_NO_ANALYTICS = "True";

        # Only available inside VPN
        WEBUI_AUTH = "False";

        # Use loopback because Open-WebUI and SearXNG run on pius, avoiding the Tailscale-authenticated public vhost.
        ENABLE_WEB_SEARCH = "True";
        WEB_SEARCH_ENGINE = "searxng";
        SEARXNG_QUERY_URL = "http://127.0.0.1:${toString config.services.searx.settings.server.port}/search?q=<query>";
        SEARXNG_LANGUAGE = "all";
        WEB_SEARCH_RESULT_COUNT = "5";

        # STATE: environment file?
        # - disable ollama
        # - remove openai api
        # - add deepseek api
        # https://api-docs.deepseek.com/
        # base url: https://api.deepseek.com
      };
    };

    homer.entries = [
      {
        name = "Open WebUI";
        subtitle = "Chat";
        url = "https://${domain}";
        logo = "/assets/icons/open-webui.svg";
        group = "ai";
      }
    ];
  };

  systemd = {
    services.open-webui = {
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = user;

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/open-webui" ];
      };
    };
  };

  users = {
    users = {
      open-webui = {
        group = user;
        isSystemUser = true;
      };
    };

    groups.open-webui = { };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/open-webui";
      inherit user;
      group = user;
    }
    # {
    #   directory = "/var/lib/private/open-webui";
    #   parentDirectory.mode = "0700";
    # }
  ];
}
