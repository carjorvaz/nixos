{
  config,
  self,
  ...
}:

let
  # Nginx resolves proxyPass hostnames at startup. Use pius's stable Tailscale
  # IPv4 address so hadrianus can switch before MagicDNS is warm.
  piusTailscaleIPv4 = "100.121.87.116";
  clOttInternalHost = "cl-ott.pius.internal";
  clOttUpdateRoot = "/var/www/ott.vaz.one";
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
    limit_req_zone $binary_remote_addr zone=cl_ott_api:10m rate=5r/s;
    limit_req_zone $binary_remote_addr zone=cl_ott_updates:10m rate=6r/m;
    limit_conn_zone $binary_remote_addr zone=cl_ott_addr:10m;
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
      locations."/".proxyPass = "http://${piusTailscaleIPv4}:${toString config.services.seerr.port}";
    };

    "ott.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      root = clOttUpdateRoot;

      extraConfig = ''
        server_tokens off;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Cache-Control "no-store" always;
        add_header Cross-Origin-Resource-Policy "same-origin" always;
      '';

      locations."/" = {
        return = "404";
      };

      locations."= /_cl_ott_auth" = {
        proxyPass = "http://${piusTailscaleIPv4}:80/api/v1/status";
        recommendedProxySettings = false;
        extraConfig = ''
          internal;
          proxy_pass_request_body off;
          proxy_set_header Content-Length "";
          proxy_set_header Host ${clOttInternalHost};
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Authorization $http_authorization;
        '';
      };

      locations."^~ /app/" = {
        tryFiles = "$uri =404";
        extraConfig = ''
          auth_request /_cl_ott_auth;
          limit_req zone=cl_ott_updates burst=3 nodelay;
          limit_req_status 429;
          limit_conn cl_ott_addr 2;
          disable_symlinks on from=$document_root;
          default_type application/octet-stream;
          types {
            application/json json;
            application/vnd.android.package-archive apk;
          }

          if ($uri !~ "^/app/(latest\.json|tv-[0-9][0-9A-Za-z._-]*\.apk)$") {
            return 404;
          }

          limit_except GET {
            deny all;
          }
        '';
      };

      locations."^~ /api/v1/" = {
        proxyPass = "http://${piusTailscaleIPv4}:80";
        recommendedProxySettings = false;
        extraConfig = ''
          client_max_body_size 1k;
          limit_req zone=cl_ott_api burst=30 nodelay;
          limit_req_status 429;
          limit_conn cl_ott_addr 8;

          proxy_connect_timeout 5s;
          proxy_read_timeout 20s;
          proxy_send_timeout 20s;
          proxy_buffering off;
          proxy_max_temp_file_size 0;
          proxy_set_header Host ${clOttInternalHost};
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header X-Forwarded-Host $host;
          proxy_set_header X-Forwarded-Server $hostname;
          proxy_set_header Connection "";
          proxy_set_header Authorization $http_authorization;

          if ($request_method !~ "^(GET|POST)$") {
            return 405;
          }

          if ($http_authorization !~ "^Bearer .+") {
            return 401;
          }
        '';
      };
    };

    "lisp.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
      basicAuthFile = lispCorpusHtpasswdFile;

      extraConfig = ''
        server_tokens off;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
        add_header Cache-Control "private, no-store" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Content-Security-Policy "default-src 'self'; style-src 'self' 'unsafe-inline'; object-src 'none'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'" always;
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
          proxy_buffering off;
          proxy_max_temp_file_size 0;
          proxy_set_header Authorization $http_authorization;
        '';
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d ${clOttUpdateRoot} 0755 root nginx - -"
    "d ${clOttUpdateRoot}/app 0755 root nginx - -"
    "Z ${clOttUpdateRoot} 0755 root nginx - -"
  ];
}
