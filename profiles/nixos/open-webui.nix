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
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.open-webui.port}";
        proxyWebsockets = true;
      };
    };

    open-webui = {
      enable = true;
      package = pkgs.unstable.open-webui;
      port = 11111;

      environment = {
        ANONYMIZED_TELEMETRY = "False";
        DO_NOT_TRACK = "True";
        SCARF_NO_ANALYTICS = "True";

        # Only available inside VPN
        WEBUI_AUTH = "False";

        # Web Search
        ENABLE_RAG_WEB_SEARCH = "True";
        SEARXNG_QUERY_URL = "https://searx.vaz.ovh/search?q=<query>";
        RAG_WEB_SEARCH_ENGINE = "searxng";

        # STATE: environment file?
        # - disable ollama
        # - remove openai api
        # - add deepseek api
        # https://api-docs.deepseek.com/
        # base url: https://api.deepseek.com
      };
    };
  };

  systemd = {
    services.open-webui = {
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = user;
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
      user = user;
      group = user;
    }
    # {
    #   directory = "/var/lib/private/open-webui";
    #   parentDirectory.mode = "0700";
    # }
  ];
}
