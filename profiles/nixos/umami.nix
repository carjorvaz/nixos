{ self, config, ... }:

let
  domain = "umami.carjorvaz.com";
  upstream = "http://127.0.0.1:${toString config.services.umami.settings.PORT}";
in
{
  # Umami 3.1.0's Next 16/Turbopack build currently completes without
  # emitting .next/standalone, while the nixpkgs package installPhase expects
  # that output. Use webpack for this package until the upstream package moves
  # past the Turbopack/standalone mismatch.
  nixpkgs.overlays = [
    (_final: prev: {
      umami = prev.umami.overrideAttrs (old: {
        env = (old.env or { }) // {
          # Webpack needs more than Node's default ~1 GiB V8 heap for Umami's
          # production build. This is build-time only; the service wrapper
          # does not inherit derivation env vars at runtime.
          NODE_OPTIONS = "--max-old-space-size=1536";
        };

        postPatch = (old.postPatch or "") + ''
          substituteInPlace package.json \
            --replace-fail '"build-app": "next build --turbo"' '"build-app": "next build --webpack"'
        '';
      });
    })
  ];

  age.secrets.umamiAppSecret.file = "${self}/secrets/umamiAppSecret.age";

  services = {
    nginx.appendHttpConfig = ''
      limit_req_zone $binary_remote_addr zone=umami_login:10m rate=10r/m;
      limit_req_status 429;
    '';

    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      enableACME = true;
      locations = {
        # Public endpoints needed by visitors' browsers for analytics.
        "= /script.js".proxyPass = upstream;
        "= /beacon.js".proxyPass = upstream;
        "= /app.js".proxyPass = upstream;
        "= /api/v2/collect".proxyPass = upstream;

        # Public dashboard; Umami's own login protects the application.
        "= /api/auth/login" = {
          proxyPass = upstream;
          extraConfig = ''
            limit_req zone=umami_login burst=5 nodelay;
          '';
        };

        "/" = {
          proxyPass = upstream;
        };
      };
    };

    umami = {
      enable = true;
      createPostgresqlDatabase = true;
      settings = {
        DISABLE_TELEMETRY = true;
        TRACKER_SCRIPT_NAME = [
          "script.js"
          "beacon.js"
          "app.js"
        ];
        COLLECT_API_ENDPOINT = "/api/v2/collect";
        APP_SECRET_FILE = config.age.secrets.umamiAppSecret.path;
      };
    };
  };

  environment.persistence."/persist".directories = [ "/var/lib/postgresql" ];
}
