{ config, lib, pkgs, ... }:

{
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "carlos+letsencrypt@vaz.one";
  };

  services.nginx = {
    enable = true;

    # Use recommended settings
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts = {
      # "example.org" = {
      #   forceSSL = true;
      #   enableACME = true;
      #   root = "/var/www/myhost.org";
      #   locations."/".proxyPass = "http://127.0.0.1:12345";
      #   globalRedirect = "newserver.example.org";
      # };

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
    };
  };
}
