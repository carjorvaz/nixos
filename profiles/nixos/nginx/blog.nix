{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./common.nix ];

  services.nginx.virtualHosts = {
    "carlosvaz.net" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carjorvaz.com";
    };

    "cjv.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "carlosvaz.pt";
    };

    "carjorvaz.com" = {
      forceSSL = true;
      enableACME = true;
      root = "/var/www/carjorvaz.com/";
    };

    "carlosvaz.pt" = {
      forceSSL = true;
      enableACME = true;
      root = "/var/www/carlosvaz.pt/";
    };

    "mafaldaribeiro.pt" = {
      forceSSL = true;
      enableACME = true;
      globalRedirect = "mafaldaribeiro.com";
    };
  };

  environment.persistence."/persist".directories = [ "/var/www" ];
}
