{ config, lib, pkgs, ... }:

let
  domain = "books.vaz.ovh";
  library = "/persist/media/books";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass =
        "http://127.0.0.1:${toString config.services.calibre-web.listen.port}";
    };

    calibre-server = {
      enable = true;
      user = "media";
      libraries = [ library ];
    };

    calibre-web = {
      enable = true;
      user = "media";
      listen.ip = "0.0.0.0";
      options = {
        calibreLibrary = library;
        enableBookConversion = true;
      };
    };
  };

  systemd.services.calibre-server.serviceConfig.ExecStart = lib.mkForce
    "${pkgs.calibre}/bin/calibre-server --userdb ${library}/users.sqlite --enable-auth ${library}";

  environment.persistence."/persist".directories = [ "/var/lib/calibre-web" ];
}
