{ ... }:

let
  domain = "prowlarr.vaz.ovh";
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
        locations."/".proxyPass = "http://127.0.0.1:9696";
      };
    };

    prowlarr.enable = true;

    homer.entries = [
      {
        name = "Prowlarr";
        subtitle = "Indexers";
        url = "https://${domain}";
        logo = "/assets/icons/prowlarr.svg";
        group = "arr";
      }
    ];
  };

  environment.persistence."/persist".directories = [ "/var/lib/private/prowlarr" ];
}
