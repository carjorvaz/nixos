{ config, lib, pkgs, ... }:

let domain = "jackett.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:9117";
    };

    jackett.enable = true;
  };

  # environment.persistence."/persist".directories = [ "/var/lib/jackett" ];
}
