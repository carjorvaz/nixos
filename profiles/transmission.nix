{ config, lib, pkgs, ... }:

# Manage remotely using: ssh -L 9091:localhost:9091 commodus and acessing localhost:9091
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

  # Requires: chgrp --recursive media /var/lib/transmission/Downloads
  users.users.transmission.extraGroups = [ "media" ];

  # environment.persistence."/persist".directories = [ "/var/lib/transmission" ];
}
