{ config, lib, pkgs, ... }:

let domain = "jellyfin.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:8096";
    };

    jellyfin.enable = true;
  };

  # Requires: chgrp --recursive media /persist/media && chmod -R g+w /persist/media
  users.groups.media = { }; # Creates the media group
  users.users.jellyfin.extraGroups = [ "media" ];

  # environment.persistence."/persist".directories = [ "/var/lib/jellyfin" ];
}
