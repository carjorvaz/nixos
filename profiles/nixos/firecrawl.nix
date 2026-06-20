{ config, pkgs, ... }:

let
  domain = "firecrawl.vaz.ovh";
  firecrawl = config.services.firecrawl;
in
{
  services = {
    firecrawl = {
      enable = true;
      package = pkgs.firecrawl;
      publicUrl = domain;

      # This singleton is private behind nginx + Tailscale auth, so keep
      # Firecrawl's Supabase-style API-key machinery disabled and bind only
      # to loopback in the generic service module.
      useDbAuthentication = false;

      environment = {
        # Production must not allow private/loopback fetch bypasses.
        ALLOW_LOCAL_WEBHOOKS = false;
      };
    };

    nginx = {
      tailscaleAuth = {
        enable = true;
        virtualHosts = [ domain ];
      };

      virtualHosts.${domain} = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/" = {
          proxyPass = "http://${firecrawl.bindAddress}:${toString firecrawl.port}";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_connect_timeout 30s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
          '';
        };
      };
    };

    homer.entries = [
      {
        name = "Firecrawl";
        subtitle = "Web extraction";
        url = "https://${domain}";
        logo = "";
        group = "ai";
      }
    ];
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/firecrawl";
      user = "firecrawl";
      group = "firecrawl";
      mode = "0700";
    }
    {
      directory = "/var/cache/firecrawl";
      user = "firecrawl";
      group = "firecrawl";
      mode = "0700";
    }
  ];
}
