{ config, lib, pkgs, ... }:

let domain = "sonarr.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:8989";
    };

    sonarr = {
      enable = true;
      user = "media";
    };
  };

  environment.persistence."/persist".directories = [ "/var/lib/sonarr" ];
}
