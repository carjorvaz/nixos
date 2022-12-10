{ config, lib, pkgs, ... }:

# Backup notes:
# - https://docs.nextcloud.com/server/latest/admin_manual/maintenance/backup.html
# - https://docs.nextcloud.com/server/latest/admin_manual/maintenance/restore.html
# - /var/lib/nextcloud must be owned by nextcloud (sudo chown -R nextcloud: /var/lib/nextcloud)
let domain = "cloud.vaz.one";
in {
  services = {
    nginx.virtualHosts."${domain}" = {
      forceSSL = true;
      enableACME = true;
    };

    nextcloud = {
      enable = true;
      package = pkgs.nextcloud25; # Need to manually increment with every update
      hostName = domain;

      https = true;
      autoUpdateApps.enable = true;

      enableBrokenCiphersForSSE = false;

      extraAppsEnable = true;
      extraApps = with pkgs.nextcloud25Packages.apps; [
        calendar
        contacts
        mail
        news
        notes
        photos
        tasks
      ];

      config = {
        overwriteProtocol = "https";
        defaultPhoneRegion = "PT";

        dbtype = "pgsql";
        dbuser = "nextcloud";
        dbhost =
          "/run/postgresql"; # nextcloud will add /.s.PGSQL.5432 by itself
        dbname = "nextcloud";
        dbpassFile = "/persist/secrets/nextcloud/nextcloud-db-pass";

        adminpassFile = "/persist/secrets/nextcloud/nextcloud-admin-pass";
        adminuser = "admin";
      };
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

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
