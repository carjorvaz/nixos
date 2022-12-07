{ config, lib, pkgs, ... }:

let
  # Keep up-to-date. Instructions at https://hub.docker.com/_/ghost
  version = "5.25.1";
in {
  services.nginx.virtualHosts = {
    "mafaldaribeiro.com" = {
      forceSSL = true;
      enableACME = true;
      locations."/".proxyPass = "http://127.0.0.1:3001";
    };

    "mafaldaribeiro.pt" = {
      forceSSL = true;
      enableACME = true;
      locations."/".proxyPass = "http://127.0.0.1:3002";
    };
  };

  virtualisation.oci-containers.containers = {
    "ghost-mafalda-com" = {
      image = "ghost:${version}";
      autoStart = true;
      ports = [ "3001:2368" ];
      environment.url = "https://mafaldaribeiro.com";
      volumes = [ "/persist/mafalda/ghost_com:/var/lib/ghost/content" ];
    };

    "ghost-mafalda-pt" = {
      image = "ghost:${version}";
      autoStart = true;
      ports = [ "3002:2368" ];
      environment.url = "https://mafaldaribeiro.pt";
      volumes = [ "/persist/mafalda/ghost_pt:/var/lib/ghost/content" ];
    };
  };
}
