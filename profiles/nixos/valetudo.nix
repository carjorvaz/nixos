_:
let
  domain = "valetudo.trajanus.vaz.ovh";
  robotHost = "192.168.1.140";
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
    # MQTT must be reachable by the robot on the apartment LAN.
    # Keep this listener LAN-only via the firewall and tighten to
    # credentialed agenix users later if MQTT is exposed beyond the apartment LAN.
    mosquitto = {
      enable = true;
      persistence = true;
      listeners = [
        {
          address = "0.0.0.0";
          port = 1883;
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

  networking.firewall.interfaces.enp103s0f4u1.allowedTCPPorts = [ 1883 ];
}
