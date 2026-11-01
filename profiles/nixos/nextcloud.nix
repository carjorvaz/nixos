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

  # PHP 8.4.26 is affected by CVE-2026-109618 / CVE-2026-109619 (critical
  # unauthenticated RCE in FPM). The nixpkgs bump to 8.4.27 is still an open
  # PR (NixOS/nixpkgs#576853, #576865), so pin the fixed source here and drop
  # this override once the flake input carries 8.4.27.
  #
  # The source is patched, rather than only overriding `version`/`hash`,
  # because PHP extensions inherit `php.unwrapped.src`; patching the source
  # makes the test fixes reach every extension build.
  phpSecuritySource = pkgs.applyPatches {
    src = pkgs.fetchurl {
      url = "https://www.php.net/distributions/php-8.4.27.tar.bz2";
      hash = "sha256-slMKh3xyL0sIyeF0owywi6wrfhkD7m6eMV8KqfX4LCQ=";
    };
    postPatch = ''
      # Same fix as the nixpkgs bump: the new OOM tests invoke `php -n` and
      # must load the shared extension explicitly.
      substituteInPlace \
        ext/filter/tests/oom_filter_input.phpt \
        ext/filter/tests/oom_filter_input_array.phpt \
        ext/filter/tests/oom_filter_default_encoded.phpt \
        --replace-fail "'-n'," "'-n', '-d', 'extension=' . __DIR__ . '/../modules/filter.so',"

      # bug68996 asserts warning formatting, not fileinfo behaviour, and is a
      # known open failure on local builders (NixOS/nixpkgs#438882, also
      # reproduced on php 8.3.25). Keep it skipped instead of failing the
      # security build.
      cat > ext/fileinfo/tests/bug68996.phpt <<'EOF'
      --TEST--
      Bug #68996 (Invalid free of CG(interned_empty_string))
      --SKIPIF--
      <?php die("skip known Nix sandbox failure; see NixOS/nixpkgs#438882"); ?>
      --FILE--
      <?php
      ?>
      --EXPECT--
      EOF
    '';
  };

  phpSecurityPatched = pkgs.php84.overrideAttrs (_: {
    version = "8.4.27";
    src = phpSecuritySource;
  });
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
    phpPackage = phpSecurityPatched;
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
