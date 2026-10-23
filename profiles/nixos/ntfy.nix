_:

let
  domain = "ntfy.vaz.one";
in
{
  services = {
    ntfy-sh = {
      enable = true;
      settings = {
        base-url = "https://${domain}";
        behind-proxy = true;
        auth-default-access = "deny-all";
      };
    };

    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/" = {
        proxyPass = "http://127.0.0.1:2586";
        proxyWebsockets = true;
      };
    };
  };

  # The upstream unit has Restart=no, so an OOM kill leaves push notifications
  # silently dead.
  systemd.services.ntfy-sh.serviceConfig = {
    Restart = "always";
    RestartSec = "2s";
  };

  environment.persistence."/persist".directories = [
    "/var/lib/private/ntfy-sh"
  ];
}
