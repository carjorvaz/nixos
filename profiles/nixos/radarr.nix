{ ... }:

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

    radarr.enable = true;

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

  users.users.radarr.extraGroups = [ "media" ];

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/radarr"; user = "radarr"; group = "radarr"; }
  ];
}
