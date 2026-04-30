{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./common.nix ];

  services.nginx.virtualHosts = {
    "www.carjorvaz.com" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.com";
    };

    "carjorvaz.com" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.com";
    };

    "www.carlosvaz.net" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.com";
    };

    "carlosvaz.net" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.com";
    };

    "www.carlosvaz.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.com";
    };

    "carlosvaz.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.com";
    };

    "www.carlosvaz.com" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.com";
    };

    "carlosvaz.com" = {
      forceSSL = true;
      enableACME = true;
      root = "/var/www/carlosvaz.com/";
    };

    "www.cjv.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.pt";
    };

    "cjv.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.pt";
    };

    "www.mafaldaribeiro.com" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "mafaldaribeiro.com";
    };

    "www.mafaldaribeiro.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "mafaldaribeiro.com";
    };

    "mafaldaribeiro.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "mafaldaribeiro.com";
    };
  };

  environment.persistence."/persist".directories = [ "/var/www" ];
}
