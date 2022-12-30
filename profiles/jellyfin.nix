{ config, lib, pkgs, ... }:

let domain = "jellyfin.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:8096";
    };

    jellyfin = {
      enable = true;
      user = "media";
    };
  };

  users.users.media = {
    isNormalUser = true;
    extraGroups = [ "render" "video" ];
  };

  # environment.persistence."/persist".directories = [ "/var/lib/jellyfin" ];
}
