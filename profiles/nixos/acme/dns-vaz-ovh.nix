{ self, config, ... }:

{
  imports = [ ./common.nix ];

  age.secrets.ovh.file = "${self}/secrets/ovh.age";

  # Use services.nginx.virtualHosts."example.vaz.ovh".useACMEHost = "vaz.ovh";
  # to use the wildcard certificate on private tailnet subdomains. The nested
  # host wildcards cover names such as home-assistant.trajanus.vaz.ovh.
  security.acme.certs."vaz.ovh" = {
    domain = "vaz.ovh";
    extraDomainNames = [
      "*.vaz.ovh"
      "*.pius.vaz.ovh"
      "*.trajanus.vaz.ovh"
    ];
    dnsProvider = "ovh";
    dnsPropagationCheck = true;
    environmentFile = config.age.secrets.ovh.path;
  };

  users.users.nginx.extraGroups = [ "acme" ];
}
