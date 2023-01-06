{ config, lib, pkgs, ... }:

let domain = "headscale.vaz.one";
in {
  services = {
    headscale = {
      enable = true;
      serverUrl = "https://${domain}";
      dns = { baseDomain = "vaz.ovh"; };
      settings = { logtail.enabled = false; };
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

  networking.firewall.allowedTCPPorts = [ 80 443 ];

  environment.systemPackages = [ config.services.headscale.package ];
  environment.persistence."/persist".directories = [ "/var/lib/headscale" ];
}
