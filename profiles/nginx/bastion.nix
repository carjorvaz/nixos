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

    "ombi.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://commodus:5000";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
