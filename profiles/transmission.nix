{ config, lib, pkgs, ... }:

let domain = "transmission.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:9091";
    };

    transmission = {
      enable = true;
      openFirewall = true;
    };
  };

  # environment.persistence."/persist".directories = [ "/var/lib/transmission" ];
}
