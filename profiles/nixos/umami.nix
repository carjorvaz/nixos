{ self, config, ... }:

let
  domain = "umami.carjorvaz.com";
  upstream = "http://127.0.0.1:${toString config.services.umami.settings.PORT}";
in
{
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
