{ config, lib, pkgs, ... }:

let domain = "jellyseerr.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass =
        "http://127.0.0.1:${toString config.services.jellyseerr.port}";
    };

    jellyseerr.enable = true;
  };

  environment.persistence."/persist".directories =
    [ "/var/lib/private/jellyseerr" ];
}
