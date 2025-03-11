{ config, ... }:

let
  domain = "searx.vaz.ovh";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:${toString config.services.searx.settings.server.port}";
    };

    searx = {
      enable = true;

      settings = {
        server.port = 8888;
        server.bind_address = "127.0.0.1";
        # TODO agenix secret key (not urgent because only available through VPN)
        # server.secret_key = "@SEARX_SECRET_KEY@";
        server.secret_key = "test123";

        search.formats = [
          "html"
          "json"
        ];
      };
    };
  };
}
