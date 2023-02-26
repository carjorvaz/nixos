{ config, lib, pkgs, ... }:

{
  services.nginx.virtualHosts = {
    "mafaldaribeiro.com" = {
      forceSSL = true;
      enableACME = true;
      root = "/var/www/mafaldaribeiro.com/";
    };

    "mafaldaribeiro.pt" = {
      forceSSL = true;
      enableACME = true;
      root = "/var/www/mafaldaribeiro.pt/";
    };
  };

  users.users.mafalda = {
    isNormalUser = true;
    description = "Mafalda";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL5d/rf4ll9/LefH6LTiaGopG4LrIMMAAPYMYBDFWMNm mafalda@bumblebee"
    ];
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/www/mafaldaribeiro.pt";
      user = "mafalda";
      group = "mafalda";
    }
    {
      directory = "/var/www/mafaldaribeiro.com";
      user = "mafalda";
      group = "mafalda";
    }
  ];
}
