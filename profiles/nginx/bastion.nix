{ config, lib, pkgs, ... }:

{
  services.nginx.virtualHosts = {
    "cloud.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://commodus:80";
    };

    "jellyfin.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://commodus:8096";
    };

    "jellyseerr.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass =
        "http://commodus:${toString config.services.jellyseerr.port}";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
