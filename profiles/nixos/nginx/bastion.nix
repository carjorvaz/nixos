{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Nginx resolves proxyPass hostnames at startup. Use pius's stable Tailscale
  # IPv4 address so hadrianus can switch before MagicDNS is warm.
  piusTailscaleIPv4 = "100.121.87.116";
in
{
  imports = [ ./common.nix ];

  services.nginx.virtualHosts = {
    "cloud.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://${piusTailscaleIPv4}:80";
    };

    "jellyfin.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://${piusTailscaleIPv4}:8096";
    };

    "jellyseerr.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://${piusTailscaleIPv4}:${toString config.services.jellyseerr.port}";
    };
  };
}
