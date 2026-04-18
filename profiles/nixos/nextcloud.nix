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
  nextcloudOccHelpers = with pkgs; [
    procps
    which
  ];
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

  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud33; # Need to manually increment with every update
    hostName = domain;
    database.createLocally = true;
    configureRedis = true;

    maxUploadSize = "16G";
    https = true;

    extraAppsEnable = true;
    extraApps =
      let
        packagedApps = config.services.nextcloud.package.packages.apps;
        memoriesApp = pkgs.nextcloud-app-memories;

        # nixpkgs 25.11's Nextcloud 33 app index dropped `news`, but pius
        # still has it enabled in production. Keep shipping the last
        # known-good Nextcloud 33 release until nixpkgs reintroduces it.
        newsApp =
          if packagedApps ? news then
            packagedApps.news
          else
            pkgs.fetchNextcloudApp {
              appName = "news";
              appVersion = "28.0.1";
              url = "https://github.com/nextcloud/news/releases/download/28.0.1/news.tar.gz";
              hash = "sha256-53zwBxm/vUqQvc3h9od73RYxqJhh0M6lVS4//bJHMuA=";
              license = "agpl3Plus";
              description = "An RSS/Atom feed reader";
              homepage = "https://github.com/nextcloud/news";
            };

        # The app store listing is still stale for Nextcloud 33, but the
        # upstream 0.9.0 release explicitly adds NC33 compatibility.
        cameraRawPreviewsApp = pkgs.fetchNextcloudApp {
          appName = "camerarawpreviews";
          appVersion = "0.9.0";
          url = "https://github.com/ariselseng/camerarawpreviews/releases/download/v0.9.0/camerarawpreviews_nextcloud.tar.gz";
          hash = "sha256-UsvRbsNSnh4qS9nP/lEbRMMKHLZSp03azCf8lvIS7Pk=";
          license = "agpl3Only";
          description = "Preview and show camera RAW files in Nextcloud";
          homepage = "https://github.com/ariselseng/camerarawpreviews";
        };
      in
      {
        inherit (packagedApps)
          calendar
          cookbook
          contacts
          cospend
          mail
          notes
          previewgenerator # Useful on its own; required by Memories when enabled
          tasks
          ;

        camerarawpreviews = cameraRawPreviewsApp;
        memories = memoriesApp;

        news = newsApp;
      };

    settings = {
      default_phone_region = "PT";
      overwriteprotocol = "https";
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

  services.homer.entries = [
    {
      name = "Nextcloud";
      subtitle = "Cloud storage";
      url = "https://${domain}";
      logo = "/assets/icons/nextcloud.svg";
      group = "productivity";
    }
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/nextcloud";
      user = "nextcloud";
      group = "nextcloud";
    }
    "/var/lib/postgresql"
  ];

  # Some apps shell out during `occ` maintenance/activation steps. The
  # generated Nextcloud units have a deliberately small PATH, so add the
  # helpers that enabled apps such as Memories expect.
  systemd.services = {
    nextcloud-cron.path = nextcloudOccHelpers;
    nextcloud-setup.path = nextcloudOccHelpers;
    nextcloud-update-db.path = nextcloudOccHelpers;
  };
}
