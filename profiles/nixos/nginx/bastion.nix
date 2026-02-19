{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./common.nix ];

  services.nginx.virtualHosts = {
    "cloud.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://pius:80";
    };

    "jellyfin.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://pius:8096";
    };

    "jellyseerr.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://pius:${toString config.services.jellyseerr.port}";
    };
  };
}
