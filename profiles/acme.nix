{ self, config, lib, pkgs, ... }:

{
  age.secrets.ovh.file = "${self}/secrets/ovh.age";

  security.acme = {
    acceptTerms = true;
    defaults.email = "carlos+letsencrypt@vaz.one";

    certs."vaz.ovh" = {
      domain = "vaz.ovh";
      extraDomainNames = [ "*.vaz.ovh" ];
      dnsProvider = "ovh";
      dnsPropagationCheck = true;
      credentialsFile = config.age.secrets.ovh.path;
    };
  };

  users.users.nginx.extraGroups = [ "acme" ];

  # TODO clean-up; for testing purposes only
  services.nginx = {
    enable = true;

    # Use recommended settings
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts = {
      "test.vah.ovh" = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        root = "/var/www/test.vaz.ovh/";
      };
    };
  };
}
