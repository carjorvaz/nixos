{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "jellyseerr.vaz.ovh";
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
        locations."/".proxyPass = "http://127.0.0.1:${toString config.services.jellyseerr.port}";
      };
    };

    jellyseerr.enable = true;

    homer.entries = [
      {
        name = "Jellyseerr";
        subtitle = "Media requests";
        url = "https://${domain}";
        logo = "/assets/icons/jellyseerr.svg";
        group = "media";
      }
    ];
  };

  environment.persistence."/persist".directories = [ "/var/lib/private/jellyseerr" ];
}
