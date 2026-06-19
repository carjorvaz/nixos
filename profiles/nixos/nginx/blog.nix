{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./common.nix ];

  services.nginx.virtualHosts =
    let
      staticSiteSecurityHeaders = ''
        add_header Strict-Transport-Security "max-age=31536000" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Content-Security-Policy "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'self'; form-action 'none'; script-src 'self'; script-src-attr 'none'; style-src 'self'; style-src-attr 'none'; img-src 'self'; font-src 'self'; connect-src 'self'; frame-src 'none'; worker-src 'none'; media-src 'self'; manifest-src 'self'" always;
      '';

      staticSiteDefaultCacheHeader = ''
        add_header Cache-Control "no-cache" always;
      '';

      staticSiteImmutableImageHeaders = staticSiteSecurityHeaders + ''
        expires 1y;
        add_header Cache-Control "public, immutable" always;
      '';

      staticSiteBeaconProxyHeaders = staticSiteSecurityHeaders + ''
        proxy_hide_header Cache-Control;
        add_header Cache-Control "public, max-age=86400, must-revalidate" always;
      '';

      staticSiteCollectProxyHeaders = staticSiteSecurityHeaders + ''
        proxy_hide_header Cache-Control;
        add_header Cache-Control "no-store" always;
      '';

      umamiUpstream = "http://127.0.0.1:${toString config.services.umami.settings.PORT}";

      movedPostRedirects = ''
        location = /posts/exponential-logarithmic-adjustment-scales-for-audio-and-brightness-in-linux/ {
          return 308 https://carlosvaz.com/posts/logarithmic-audio-and-brightness-controls-on-linux/;
        }

        location = /posts/installing-nixos-with-root-on-tmpfs-and-encrypted-zfs-on-a-netcup-vps/ {
          return 308 https://carlosvaz.com/posts/nixos-on-a-netcup-vps-with-tmpfs-root-and-encrypted-zfs/;
        }

        location = /posts/running-llms-locally-with-llama-cpp-and-open-webui-on-macos-or-linux/ {
          return 308 https://carlosvaz.com/posts/local-llms-with-llama-cpp-and-open-webui/;
        }

        location = /posts/setting-up-samba-shares-on-nixos-with-support-for-macos-time-machine-backups/ {
          return 308 https://carlosvaz.com/posts/nixos-samba-shares-for-macos-time-machine/;
        }
      '';

      withStaticSiteSecurityHeaders = lib.mapAttrs (
        _: virtualHost:
        virtualHost
        // {
          extraConfig = (virtualHost.extraConfig or "") + staticSiteSecurityHeaders;
        }
      );
    in
    withStaticSiteSecurityHeaders {
      "www.carjorvaz.com" = {
        forceSSL = true;
        enableACME = true;
        globalRedirect = "carlosvaz.com";
      };

      "carjorvaz.com" = {
        forceSSL = true;
        enableACME = true;
        globalRedirect = "carlosvaz.com";
      };

      "www.carlosvaz.net" = {
        forceSSL = true;
        enableACME = true;
        globalRedirect = "carlosvaz.com";
      };

      "carlosvaz.net" = {
        forceSSL = true;
        enableACME = true;
        globalRedirect = "carlosvaz.com";
      };

      "www.carlosvaz.pt" = {
        forceSSL = true;
        enableACME = true;
        globalRedirect = "carlosvaz.com";
      };

      "carlosvaz.pt" = {
        forceSSL = true;
        enableACME = true;
        globalRedirect = "carlosvaz.com";
      };

      "www.carlosvaz.com" = {
        forceSSL = true;
        enableACME = true;
        globalRedirect = "carlosvaz.com";
      };

      "carlosvaz.com" = {
        forceSSL = true;
        enableACME = true;
        root = "/var/www/carlosvaz.com/";
        extraConfig = movedPostRedirects + staticSiteDefaultCacheHeader;
        locations = {
          "= /beacon.js" = {
            proxyPass = umamiUpstream;
            extraConfig = staticSiteBeaconProxyHeaders;
          };
          "= /api/v2/collect" = {
            proxyPass = umamiUpstream;
            extraConfig = staticSiteCollectProxyHeaders;
          };
          "~ ^/images/(?:.*/)?[^/]*_hu_[^/]*\\.(?:png|jpg|jpeg|webp)$".extraConfig =
            staticSiteImmutableImageHeaders;
        };
      };

      "www.cjv.pt" = {
        forceSSL = true;
        enableACME = true;
        globalRedirect = "carlosvaz.com";
      };

      "cjv.pt" = {
        forceSSL = true;
        enableACME = true;
        globalRedirect = "carlosvaz.com";
      };

    };

  users = {
    groups.carlosvaz-deploy = { };

    users.carlosvaz-deploy = {
      isSystemUser = true;
      group = "carlosvaz-deploy";
      home = "/var/empty";
      createHome = false;
      shell = pkgs.bashInteractive;
      openssh.authorizedKeys.keys = [
        "restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEuy5fn0e3ine80QNNa9TS2apicrsv+JDLZjpfEnPKZC github-actions-carlosvaz.com-20260430"
      ];
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/www/carlosvaz.com 0755 carlosvaz-deploy carlosvaz-deploy - -"
    "Z /var/www/carlosvaz.com 0755 carlosvaz-deploy carlosvaz-deploy - -"
  ];

  environment.persistence."/persist".directories = [ "/var/www" ];
}
