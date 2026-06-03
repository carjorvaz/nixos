{
  config,
  lib,
  ...
}:

let
  domain = "cl-ott-web.vaz.ovh";
  port = 4243;
  securityHeaders = ''
    server_tokens off;
    add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
  '';
  noStoreHeaders = ''
    ${securityHeaders}
    add_header Cache-Control "no-store" always;
  '';
in
{
  services.cl-ott-web = {
    enable = true;
    inherit port;
    host = "127.0.0.1";
    clientApiBaseUrl = "http://127.0.0.1:${toString config.services.cl-ott.clientApi.port}";
    clientApiTokenFile = config.age.secrets.clOttClientApiToken.path;
  };

  systemd.services.cl-ott-web = {
    after = [ "cl-ott-client-api.service" ];
    wants = [ "cl-ott-client-api.service" ];
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/cl-ott-web";
      user = "cl-ott-web";
      group = "cl-ott-web";
      mode = "0700";
    }
  ];

  services.nginx = {
    tailscaleAuth = {
      enable = true;
      virtualHosts = [ domain ];
    };

    virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";

      extraConfig = securityHeaders;

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString port}";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_connect_timeout 5s;
          proxy_read_timeout 60s;
          proxy_send_timeout 60s;
        '';
      };

      locations."/service-worker.js".extraConfig = noStoreHeaders;

      locations."/play".extraConfig = noStoreHeaders;

      locations."^~ /playback/".extraConfig = noStoreHeaders;
    };
  };
}
