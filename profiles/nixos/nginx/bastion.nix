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

    # https://github.com/plausible/community-edition/blob/v2.1.1/reverse-proxy/nginx/plausible
    "plausible.carjorvaz.com" = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = "http://pius:${toString config.services.plausible.server.port}";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        '';
      };
    };
  };
}
