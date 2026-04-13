{ self, config, ... }:

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

  environment.persistence."/persist".directories = [
    "/var/lib/private/ntfy-sh"
  ];
}
