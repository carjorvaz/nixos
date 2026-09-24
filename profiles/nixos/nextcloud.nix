{
  self,
  config,
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
    package = pkgs.nextcloud34; # Major upgrades require an app compatibility review.
    hostName = domain;
    database.createLocally = true;
    configureRedis = true;

    maxUploadSize = "16G";
    https = true;

    extraAppsEnable = true;
    extraApps =
      let
        packagedApps = config.services.nextcloud.package.packages.apps;
        cameraRawPreviewsApp =
          (pkgs.fetchNextcloudApp {
            appName = "camerarawpreviews";
            appVersion = "1.1.3";
            url = "https://github.com/ariselseng/camerarawpreviews/releases/download/v1.1.3/camerarawpreviews_nextcloud.tar.gz";
            hash = "sha256-d3SxLG99pQvU+IsCvAV0DkRIo4pP1fmP610IqtX7E+w=";
            license = "agpl3Only";
            description = "Preview and show camera RAW files in Nextcloud";
            homepage = "https://github.com/ariselseng/camerarawpreviews";
          }).overrideAttrs
            (old: {
              # The bundled RAW fallback needs the NixOS loader and C++ runtime.
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.autoPatchelfHook ];
              buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.stdenv.cc.cc.lib ];
              phases = old.phases ++ [ "fixupPhase" ];
            });
      in
      {
        inherit (packagedApps)
          calendar
          cookbook
          contacts
          cospend
          mail
          memories
          news
          notes
          previewgenerator # Useful on its own; required by Memories when enabled
          tasks
          ;

        camerarawpreviews = cameraRawPreviewsApp;
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
    nextcloud-setup = {
      path = nextcloudOccHelpers;
      postStart = ''
        ${config.services.nextcloud.occ}/bin/nextcloud-occ app:disable app_api
      '';
    };
    nextcloud-update-db.path = nextcloudOccHelpers;
  };
}
