_:

{
  services = {
    # Apartment-local broker for Valetudo -> Home Assistant discovery/state.
    # MQTT must be reachable by the robot on the apartment LAN.
    # Keep this listener LAN-only via the firewall and tighten to
    # credentialed agenix users later if MQTT is exposed beyond wlan0.
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
  };

  networking.firewall.interfaces.wlan0.allowedTCPPorts = [ 1883 ];
}
