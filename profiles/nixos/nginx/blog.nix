{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./common.nix ];

  users = {
    groups.carlosvaz-deploy = { };

    users.carlosvaz-deploy = {
      isSystemUser = true;
      group = "carlosvaz-deploy";
      home = "/var/empty";
      createHome = false;
      shell = pkgs.bashInteractive;
      openssh.authorizedKeys.keys = [
        "restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEuy5fn0e3ine80QNNa9TS2apicrsv+JDLZjpfEnPKZC github-actions-carlosvaz.com-20260430"
      ];
    };
  };

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

  systemd.tmpfiles.rules = [
    "d /var/www/carlosvaz.com 0755 carlosvaz-deploy carlosvaz-deploy - -"
    "Z /var/www/carlosvaz.com 0755 carlosvaz-deploy carlosvaz-deploy - -"
  ];

  environment.persistence."/persist".directories = [ "/var/www" ];
}
