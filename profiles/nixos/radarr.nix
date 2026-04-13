{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "radarr.vaz.ovh";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:7878";
    };

    radarr = {
      enable = true;
      user = "media";
    };

    homer.entries = [
      {
        name = "Radarr";
        subtitle = "Movies";
        url = "https://${domain}";
        logo = "/assets/icons/radarr.svg";
        group = "arr";
      }
    ];
  };

  environment.persistence."/persist".directories = [ "/var/lib/radarr" ];
}
