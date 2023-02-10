{ config, lib, pkgs, ... }:

let domain = "gotify.vaz.ovh";
in {

  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:8082";
    };

    gotify = {
      enable = true;
      port = 8082;
    };
  };

  environment.persistence."/persist".directories = [ "/var/lib/gotify-server" ];
}
