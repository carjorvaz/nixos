{
  self,
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./common.nix ];

  age.secrets.ovh.file = "${self}/secrets/ovh.age";

  # Use services.nginx.virtualHosts."example.vaz.one".useACMEHost = "vaz.one";
  # to use the wildcard certificate on subdomains.
  security.acme.certs."vaz.one" = {
    domain = "vaz.one";
    extraDomainNames = [ "*.vaz.one" ];
    dnsProvider = "ovh";
    dnsPropagationCheck = true;
    credentialsFile = config.age.secrets.ovh.path;
  };

  users.users.nginx.extraGroups = [ "acme" ];
}
