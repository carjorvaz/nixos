{ self, config, lib, pkgs, ... }:

# Backup notes:
# - https://docs.nextcloud.com/server/latest/admin_manual/maintenance/backup.html
# - https://docs.nextcloud.com/server/latest/admin_manual/maintenance/restore.html
# - /var/lib/nextcloud must be owned by nextcloud (sudo chown -R nextcloud: /var/lib/nextcloud)
let domain = "cloud.vaz.one";
in {
  age.secrets.nextcloud-db-pass = {
    file = "${self}/secrets/nextcloud-db-pass.age";
    owner = "nextcloud";
    group = "nextcloud";
  };

  age.secrets.nextcloud-admin-pass = {
    file = "${self}/secrets/nextcloud-admin-pass.age";
    owner = "nextcloud";
    group = "nextcloud";
  };

  services = {
    nextcloud = {
      enable = true;
      package = pkgs.nextcloud27; # Need to manually increment with every update
      hostName = domain;

      https = true;
      autoUpdateApps.enable = true;

      enableBrokenCiphersForSSE = false;

      extraAppsEnable = true;
      extraApps = with pkgs.nextcloud26Packages.apps; {
        inherit calendar contacts mail news notes tasks;
        cookbook = pkgs.fetchNextcloudApp rec {
          url =
            "https://github.com/nextcloud/cookbook/releases/download/v0.10.2/Cookbook-0.10.2.tar.gz";
          sha256 = "sha256-XgBwUr26qW6wvqhrnhhhhcN4wkI+eXDHnNSm1HDbP6M=";
        };
      };

      config = {
        overwriteProtocol = "https";
        defaultPhoneRegion = "PT";

        trustedProxies = [ "100.103.78.39" ];

        dbtype = "pgsql";
        dbuser = "nextcloud";
        dbhost =
          "/run/postgresql"; # nextcloud will add /.s.PGSQL.5432 by itself
        dbname = "nextcloud";
        dbpassFile = config.age.secrets.nextcloud-db-pass.path;

        adminpassFile = config.age.secrets.nextcloud-admin-pass.path;
        adminuser = "admin";
      };

      caching = {
        redis = true;
        apcu = true;
      };

      extraOptions = {
        redis = {
          host = "/run/redis-nextcloud/redis.sock";
          port = 0;
        };
        memcache = {
          local = "\\OC\\Memcache\\Redis";
          distributed = "\\OC\\Memcache\\Redis";
          locking = "\\OC\\Memcache\\Redis";
        };
      };
    };

    redis.servers.nextcloud = {
      enable = true;
      user = "nextcloud";
      port = 0;
    };

    postgresql = {
      enable = true;
      ensureDatabases = [ "nextcloud" ];
      ensureUsers = [{
        name = "nextcloud";
        ensurePermissions."DATABASE nextcloud" = "ALL PRIVILEGES";
      }];
    };
  };

  systemd.services."nextcloud-setup" = {
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/nextcloud";
      user = "nextcloud";
      group = "nextcloud";
    }
    "/var/lib/postgresql"
  ];
}
