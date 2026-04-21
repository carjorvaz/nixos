{ ... }:

let
  domain = "bazarr.vaz.ovh";
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
        locations."/".proxyPass = "http://127.0.0.1:6767";
      };
    };

    bazarr.enable = true;

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

  users.users.bazarr.extraGroups = [ "media" ];

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/bazarr"; user = "bazarr"; group = "bazarr"; }
  ];
}
