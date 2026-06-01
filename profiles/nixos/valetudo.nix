_:

let
  domain = "valetudo.trajanus.vaz.ovh";
  robotHost = "192.168.1.210";
  mqttPort = 1883;
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
          proxyPass = "http://${robotHost}:80";
          proxyWebsockets = true;
        };
      };
    };

    # Apartment-local broker for Valetudo -> Home Assistant discovery/state.
    # The HTTP UI is behind tailnet nginx auth, but MQTT must be reachable by the
    # robot on the apartment LAN. Keep this listener LAN-only via the firewall and
    # tighten to credentialed agenix users later if MQTT is exposed beyond wlan0.
    mosquitto = {
      enable = true;
      persistence = true;
      listeners = [
        {
          address = "0.0.0.0";
          port = mqttPort;
          omitPasswordAuth = true;
          settings.allow_anonymous = true;
          acl = [
            "topic readwrite valetudo/#"
            "topic readwrite homeassistant/#"
            "topic readwrite homie/#"
          ];
        }
      ];
    };

    homer.entries = [
      {
        name = "Valetudo";
        subtitle = "Dreame X40 Ultra";
        url = "https://${domain}";
        group = "home";
      }
    ];
  };

  networking.firewall.interfaces.wlan0.allowedTCPPorts = [ mqttPort ];
}
