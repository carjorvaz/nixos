{ self, config, lib, pkgs, ... }:

{
  imports = [ ./common.nix ];

  age.secrets.ovh.file = "${self}/secrets/ovh.age";

  # Use services.nginx.virtualHosts."example.vaz.ovh".useACMEHost = "vaz.ovh";
  # to use the wildcard certificate on subdomains.
  security.acme.certs."vaz.ovh" = {
    domain = "vaz.ovh";
    extraDomainNames = [ "*.vaz.ovh" ];
    dnsProvider = "ovh";
    dnsPropagationCheck = true;
    credentialsFile = config.age.secrets.ovh.path;
  };

  users.users.nginx.extraGroups = [ "acme" ];
}
