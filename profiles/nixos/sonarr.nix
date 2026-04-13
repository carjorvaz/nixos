{ ... }:

let
  domain = "sonarr.vaz.ovh";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:8989";
    };

    sonarr.enable = true;

    homer.entries = [
      {
        name = "Sonarr";
        subtitle = "TV shows";
        url = "https://${domain}";
        logo = "/assets/icons/sonarr.svg";
        group = "arr";
      }
    ];
  };

  users.users.sonarr.extraGroups = [ "media" ];

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/sonarr"; user = "sonarr"; group = "sonarr"; }
  ];
}
