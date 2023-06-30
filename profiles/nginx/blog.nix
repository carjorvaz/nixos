{ config, lib, pkgs, ... }:

{
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

    "tobepractical.com" = {
      forceSSL = true;
      enableACME = true;
      root = "/var/www/tobepractical.com/";
    };
  };

  users.users.deploy = {
    isNormalUser = true;
    description = "CI/CD Deploy User";
    home = "/var/www/tobepractical.com";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG4P33Dvt0Unn15N13kwdsgPfKTsZRecXtlezYyXV65S"
    ];
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];

  environment.persistence."/persist".directories = [ "/var/www" ];
}
