{
  self,
  config,
  lib,
  pkgs,
  ...
}:

# Backup notes:
# - https://docs.nextcloud.com/server/latest/admin_manual/maintenance/backup.html
# - https://docs.nextcloud.com/server/latest/admin_manual/maintenance/restore.html
# - /var/lib/nextcloud must be owned by nextcloud (sudo chown -R nextcloud: /var/lib/nextcloud)
let
  domain = "cloud.vaz.one";
in
{
  # STATE: still requires running after deploying
  # # chown -R nextcloud: /var/lib/nextcloud
  # # chown -R nextcloud: /persist/var/lib/nextcloud
  age.secrets.nextcloud-admin-pass = {
    file = "${self}/secrets/nextcloud-admin-pass.age";
    owner = "nextcloud";
    group = "nextcloud";
  };

  services.nginx.virtualHosts = {
    "cloud.vaz.one" = {
      forceSSL = true;
      useACMEHost = "vaz.one";
    };
  };

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud29; # Need to manually increment with every update
    hostName = domain;
    database.createLocally = true;
    configureRedis = true;

    maxUploadSize = "16G";
    https = true;

    appstoreEnable = true; # For apps that don't work declaratively or that aren't packaged in nixpkgs, so they auto-update.
    autoUpdateApps.enable = true;
    extraAppsEnable = true;
    extraApps = {
      inherit (config.services.nextcloud.package.packages.apps)
        calendar
        cookbook
        contacts
        mail
        memories # Requires setup in the admin panel
        notes
        previewgenerator # Memories dependency
        tasks
        ;
    };

    settings = {
      default_phone_region = "PT";
      overwriteprotocol = "https";
      trusted_domains = [ "https://${domain}/" ];
      trusted_proxies = [ "100.103.78.39" ];
      mail_smtpmode = "sendmail";
      mail_sendmailmode = "pipe";
    };

    config = {
      dbtype = "pgsql";
      adminuser = "admin";
      adminpassFile = config.age.secrets.nextcloud-admin-pass.path;
    };

    phpOptions = {
      "opcache.interned_strings_buffer" = "16";
    };
  };

  # Memories app dependencies.
  environment.systemPackages = with pkgs; [
    exiftool
    ffmpeg
    imagemagick
    nodejs
    perl
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/nextcloud";
      user = "nextcloud";
      group = "nextcloud";
    }
    "/var/lib/postgresql"
  ];
}
