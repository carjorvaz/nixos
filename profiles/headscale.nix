{ config, lib, pkgs, ... }:

let domain = "headscale.vaz.one";
in {
  services = {
    headscale = {
      enable = true;
      # address = "0.0.0.0" # TODO
      port = 8080;
      serverUrl = "https://${domain}";
      dns = { baseDomain = "vaz.ovh"; };

    };

    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass =
          "http://localhost:${toString config.services.headscale.port}";
        proxyWebsockets = true;
      };
    };
  };

  environment.systemPackages = [ config.services.headscale.package ];
}
