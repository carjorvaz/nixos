{ config, lib, pkgs, ... }:

{
  services.nginx.virtualHosts = {
    "jellyfin.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://100.64.0.1:8096";
    };

    "ombi.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://100.64.0.1:5000";
    };
  };
}
