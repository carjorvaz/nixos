{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./common.nix ];

  services.nginx.virtualHosts = {
    "carjorvaz.com" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.com";
    };

    "carlosvaz.net" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.com";
    };

    "carlosvaz.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.com";
    };

    "carlosvaz.com" = {
      forceSSL = true;
      enableACME = true;
      root = "/var/www/carlosvaz.com/";
    };

    "cjv.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.pt";
    };

    "mafaldaribeiro.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "mafaldaribeiro.com";
    };
  };

  environment.persistence."/persist".directories = [ "/var/www" ];
}
