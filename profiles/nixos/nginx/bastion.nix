{
  config,
  self,
  ...
}:

let
  # Nginx resolves proxyPass hostnames at startup. Use pius's stable Tailscale
  # IPv4 address so hadrianus can switch before MagicDNS is warm.
  piusTailscaleIPv4 = "100.121.87.116";
  lispCorpusHtpasswdFile = config.age.secrets.lispCorpusShareHtpasswd.path;
in
{
  imports = [ ./common.nix ];

  age.secrets = {
    lispCorpusShareHtpasswd = {
      file = "${self}/secrets/lispCorpusShareHtpasswd.age";
      owner = "root";
      group = "nginx";
      mode = "0440";
    };

    lispCorpusSharePassword = {
      file = "${self}/secrets/lispCorpusSharePassword.age";
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  services.nginx.appendHttpConfig = ''
    limit_req_zone $binary_remote_addr zone=lisp_corpus_share:10m rate=3r/s;
  '';

  services.nginx.virtualHosts = {
    "cloud.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://${piusTailscaleIPv4}:80";
    };

    "jellyfin.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://${piusTailscaleIPv4}:8096";
    };

    "jellyseerr.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      locations."/".proxyPass = "http://${piusTailscaleIPv4}:${toString config.services.jellyseerr.port}";
    };

    "lisp.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      basicAuthFile = lispCorpusHtpasswdFile;

      extraConfig = ''
        server_tokens off;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
        add_header Cache-Control "private" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Content-Security-Policy "default-src 'self'; object-src 'none'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'" always;
        add_header Cross-Origin-Resource-Policy "same-origin" always;
      '';

      locations."/" = {
        proxyPass = "http://${piusTailscaleIPv4}:80";
        extraConfig = ''
          limit_except GET {
            deny all;
          }

          limit_req zone=lisp_corpus_share burst=60 nodelay;
          limit_req_status 429;
          proxy_set_header Authorization $http_authorization;
        '';
      };
    };
  };
}
