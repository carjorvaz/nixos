{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "calibre.vaz.ovh";
  library = "/persist/media/books";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:${toString config.services.calibre-web.listen.port}";
    };

    calibre-server = {
      enable = true;
      libraries = [ library ];
    };

    calibre-web = {
      enable = true;
      listen.ip = "0.0.0.0";
      options = {
        calibreLibrary = library;
        enableBookConversion = true;
      };
    };

    homer.entries = [
      {
        name = "Calibre";
        subtitle = "E-books";
        url = "https://${domain}";
        logo = "/assets/icons/calibre-web.svg";
        group = "media";
      }
    ];
  };

  users.users.calibre-web.extraGroups = [ "media" ];
  users.users.calibre-server.extraGroups = [ "media" ];

  systemd.services.calibre-server.serviceConfig.ExecStart = lib.mkForce "${pkgs.calibre}/bin/calibre-server --userdb ${library}/users.sqlite --enable-auth ${library}";

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/calibre-web"; user = "calibre-web"; group = "calibre-web"; }
  ];
}
