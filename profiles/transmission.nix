{ config, lib, pkgs, ... }:

let domain = "transmission.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:${
          toString config.services.transmission.settings.rpc-port
        }";
    };

    transmission = {
      enable = true;
      openFirewall = true;
      settings = {
        download-dir = "/persist/media/downloads";
        rpc-whitelist-enabled = true;
        rpc-whitelist = "127.0.0.1,100.64.*.*";
        rpc-host-whitelist-enabled = true;
        rpc-host-whitelist = "*.vaz.ovh,*.rome.vaz.ovh";
        speed-limit-up-enabled = true;
        speed-limit-up = 100;
      };
    };
  };

  # Requires: chgrp --recursive media /var/lib/transmission/Downloads
  users.users.transmission.extraGroups = [ "media" ];

  # environment.persistence."/persist".directories = [ "/var/lib/transmission" ];
}
