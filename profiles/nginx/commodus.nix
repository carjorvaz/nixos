{ config, lib, pkgs, ... }:

{
  services.nginx.virtualHosts = {
    "router.vaz.ovh" = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://192.168.1.254";
    };
  };
}
