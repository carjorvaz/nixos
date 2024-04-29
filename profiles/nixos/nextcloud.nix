{ self, config, lib, pkgs, ... }:

# Backup notes:
# - https://docs.nextcloud.com/server/latest/admin_manual/maintenance/backup.html
# - https://docs.nextcloud.com/server/latest/admin_manual/maintenance/restore.html
# - /var/lib/nextcloud must be owned by nextcloud (sudo chown -R nextcloud: /var/lib/nextcloud)
let domain = "cloud.vaz.one";
in {
  # STATE: still requires running after deploying
  # # chown -R nextcloud: /var/lib/nextcloud
  # # chown -R nextcloud: /persist/var/lib/nextcloud
  age.secrets.nextcloud-admin-pass = {
    file = "${self}/secrets/nextcloud-admin-pass.age";
    owner = "nextcloud";
    group = "nextcloud";
  };

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud28; # Need to manually increment with every update
    hostName = domain;
    database.createLocally = true;
    configureRedis = true;

    maxUploadSize = "16G";
    https = true;

    autoUpdateApps.enable = true;
    extraAppsEnable = true;
    extraApps = with config.services.nextcloud.package.packages.apps; {

      inherit calendar contacts mail # memories TODO
        # news
        notes previewgenerator # Memories dependency.
        tasks;
      # # TODO fetchNextcloduApp broken no 23.11?
      # cookbook = pkgs.fetchNextcloudApp rec {
      #   url =
      #     "https://github.com/nextcloud/cookbook/releases/download/v0.10.2/Cookbook-0.10.2.tar.gz";
      #   sha256 = "sha256-XgBwUr26qW6wvqhrnhhhhcN4wkI+eXDHnNSm1HDbP6M=";
      # };
      # # Memories dependency
      # recognize = pkgs.fetchNextcloudApp rec {
      #   url =
      #     "https://github.com/nextcloud/recognize/releases/download/v6.0.0/recognize-6.0.0.tar.gz";
      #   sha256 = "sha256-zQd43bjJSMqBqoYg2LiXh2TobdHIU5HmrG2TDExjT/Q=";
      # };
    };

    config = {
      overwriteProtocol = "https";
      defaultPhoneRegion = "PT";
      trustedProxies = [ "100.103.78.39" ];
      dbtype = "pgsql";
      adminuser = "admin";
      adminpassFile = config.age.secrets.nextcloud-admin-pass.path;
    };
  };

  # Memories app dependencies.
  environment.systemPackages = with pkgs; [ exiftool ffmpeg imagemagick ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/nextcloud";
      user = "nextcloud";
      group = "nextcloud";
    }
    "/var/lib/postgresql"
  ];
}
