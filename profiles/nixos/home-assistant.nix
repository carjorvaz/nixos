{ config, lib, ... }:

let
  cfg = config.cjv.homeAssistant;
in
{
  options.cjv.homeAssistant = {
    domain = lib.mkOption {
      type = lib.types.str;
      default = "home-assistant.${config.networking.hostName}.vaz.ovh";
      description = "External DNS name used for this host's Home Assistant instance.";
    };

    homerName = lib.mkOption {
      type = lib.types.str;
      default = "Home Assistant";
      description = "Name shown for this Home Assistant instance in Homer.";
    };

    homerSubtitle = lib.mkOption {
      type = lib.types.str;
      default = "Smart home";
      description = "Subtitle shown for this Home Assistant instance in Homer.";
    };

    serverHost = lib.mkOption {
      type = lib.types.either lib.types.str (lib.types.listOf lib.types.str);
      default = "127.0.0.1";
      description = "Address or addresses Home Assistant should bind to.";
    };

    serverPort = lib.mkOption {
      type = lib.types.port;
      default = 8124;
      description = "TCP port Home Assistant should listen on.";
    };

    trustedProxies = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "127.0.0.1" ];
      description = "Reverse proxies trusted by Home Assistant's HTTP integration.";
    };

    extraComponents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional Home Assistant integration domains to include in the Nix package.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Additional Home Assistant configuration.yaml attributes.";
    };
  };

  config = {
    services = {
      # Home Assistant remains tailnet-private, but we avoid nginx-level
      # Tailscale auth for now because the mobile app and API-style clients are
      # better served by Home Assistant's own session/auth model.
      nginx.virtualHosts.${cfg.domain} = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.serverPort}";
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
        ]
        ++ cfg.extraComponents;

        config = lib.recursiveUpdate {
          # Includes dependencies for a basic setup
          # https://www.home-assistant.io/integrations/default_config/
          default_config = { };

          http = {
            server_host = cfg.serverHost;
            server_port = cfg.serverPort;
            trusted_proxies = cfg.trustedProxies;
            use_x_forwarded_for = true;
          };
        } cfg.extraConfig;
      };

      homer.entries = [
        {
          name = cfg.homerName;
          subtitle = cfg.homerSubtitle;
          url = "https://${cfg.domain}";
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
  };
}
