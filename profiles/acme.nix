{ self, config, lib, pkgs, ... }:

{
  age.secrets.ovh.file = "${self}/secrets/ovh.age";

  security.acme = {
    acceptTerms = true;
    defaults.email = "carlos+letsencrypt@vaz.one";

    # Use services.nginx.virtualHosts."example.vaz.ovh".useACMEHost = "vaz.ovh";
    # to use the wildcard certificate on subdomains.
    certs."vaz.ovh" = {
      domain = "vaz.ovh";
      extraDomainNames = [ "*.vaz.ovh" ];
      dnsProvider = "ovh";
      dnsPropagationCheck = true;
      credentialsFile = config.age.secrets.ovh.path;
    };
  };

  users.users.nginx.extraGroups = [ "acme" ];
}
