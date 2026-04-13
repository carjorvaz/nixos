{ config, ... }:

let
  domain = "home-assistant.vaz.ovh";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.home-assistant.config.http.server_port}";
        proxyWebsockets = true;
      };
    };

    home-assistant = {
      enable = true;

      # To find out components:
      # - run `❯ journalctl -efu home-assistant`
      # - find component in https://github.com/NixOS/nixpkgs/blob/master/pkgs/servers/home-assistant/component-packages.nix
      extraComponents = [
        # Components required to complete the onboarding
        "analytics"
        "google_translate"
        "met"
        "radio_browser"
        "shopping_list"
        # Recommended for fast zlib compression
        # https://www.home-assistant.io/integrations/isal
        "isal"

        "esphome"
      ];

      config = {
        # Includes dependencies for a basic setup
        # https://www.home-assistant.io/integrations/default_config/
        default_config = { };

        http = {
          server_port = 8124;
          trusted_proxies = [
            "127.0.0.1"
          ];
          use_x_forwarded_for = true;
        };
      };
    };

    homer.entries = [
      {
        name = "Home Assistant";
        subtitle = "Smart home";
        url = "https://${domain}";
        logo = "/assets/icons/home-assistant.svg";
        group = "home";
      }
    ];
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/hass";
      user = "hass";
      group = "hass";
    }
  ];
}
