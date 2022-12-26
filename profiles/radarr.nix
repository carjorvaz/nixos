{ config, lib, pkgs, ... }:

let domain = "radarr.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:7878";
    };

    radarr = {
      enable = true;
      group = "media";
    };
  };

  # environment.persistence."/persist".directories = [ "/var/lib/radarr" ];
}
