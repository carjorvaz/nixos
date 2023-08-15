{ config, lib, pkgs, ... }:

let domain = "ombi.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass =
        "http://127.0.0.1:${toString config.services.ombi.port}";
    };

    ombi = {
      enable = true;
      user = "media";
    };
  };

  environment.persistence."/persist".directories = [ "/var/lib/ombi" ];
}
