{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "bazarr.vaz.ovh";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:6767";
    };

    bazarr = {
      enable = true;
      user = "media";
    };

    homer.entries = [
      {
        name = "Bazarr";
        subtitle = "Subtitles";
        url = "https://${domain}";
        logo = "/assets/icons/bazarr.svg";
        group = "arr";
      }
    ];
  };

  environment.persistence."/persist".directories = [ "/var/lib/bazarr" ];
}
