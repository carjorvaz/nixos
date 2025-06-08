{ ... }:

let
  domain = "prowlarr.vaz.ovh";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:9696";
    };

    prowlarr.enable = true;
  };

  environment.persistence."/persist".directories = [ "/var/lib/private/prowlarr" ];
}
