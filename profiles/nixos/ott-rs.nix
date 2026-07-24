{
  self,
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  webHost = "ott-web.vaz.ovh";
  telegramSecretGroup = "telegram-secrets";
  ottRsPackage = inputs.ott-rs.packages.${pkgs.system}.default.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ../../patches/ott-rs-reject-empty-refresh.patch ];
  });
  ottRs = "${ottRsPackage}/bin/ott-rs";
  healthDir = "/var/lib/ott-rs/health";
  auditDir = "/var/lib/ott-rs/audit";
  priorityHealthSampleCommand = "${ottRs} health-sample --input ${auditDir}/channel-selection.json --output ${healthDir}/health-priority-sample.json --state-input ${healthDir}/health-state.json --state-output ${healthDir}/health-state.json --limit 1 --offset 0 --strategy focus --channel-match 'sport tv 5' --candidates-per-channel 5 --selected-failure-threshold 2 --replacement-alive-threshold 2 --timeout 8 --read-seconds 6";
in
{
  users = {
    groups.${telegramSecretGroup} = { };
    users.ott-rs.extraGroups = [ telegramSecretGroup ];
  };

  age.secrets = {
    piusTelegramEnv = {
      file = "${self}/secrets/piusTelegramEnv.age";
      owner = "root";
      group = telegramSecretGroup;
      mode = "0440";
    };

    ottTvClientApiToken = {
      file = "${self}/secrets/ottTvClientApiToken.age";
      owner = "ott-rs";
      group = "ott-rs";
      mode = "0400";
    };
  };

  services.ott-rs = {
    enable = true;
    package = ottRsPackage;
    environmentFile = config.age.secrets.piusTelegramEnv.path;
    interval = "*-*-* 00,04,08,12,16,20:00:00";
    randomizedDelaySec = "10min";
    force = true;
    telegram.enable = true;

    outputPath = "/var/lib/ott-rs/private/playlist.m3u";
    stateFile = "/var/lib/ott-rs/state/state.json";
    checkStateFile = "/var/lib/ott-rs/state/check-state.json";
    rawSourcesPath = "/var/lib/ott-rs/audit/raw-sources.json";
    sourceInventoryPath = "/var/lib/ott-rs/audit/source-inventory.json";
    channelSelectionPath = "/var/lib/ott-rs/audit/channel-selection.json";
    rankAuditPath = "/var/lib/ott-rs/audit/rank-audit.json";
    groupCatalogPath = "/var/lib/ott-rs/audit/group-catalog.json";

    guide.xmltvUrl = "https://github.com/LITUATUI/M3UPT/raw/main/EPG/epg-m3upt.xml.xz";

    health = {
      planPath = "/var/lib/ott-rs/health/health-plan.json";
      statusPath = "/var/lib/ott-rs/health/health-status.json";
      staleAfterHours = 36;
    };

    healthSample = {
      enable = true;
      limit = 20;
      candidatesPerChannel = 5;
      timeoutSeconds = 8;
      readSeconds = 6;
    };

    doctor = {
      enable = true;
      outputPath = "/var/lib/ott-rs/audit/doctor.json";
      staleAfterHours = 36;
    };

    clientApi = {
      enable = true;
      bindAddress = "127.0.0.1";
      port = 8787;
      tokenFile = config.age.secrets.ottTvClientApiToken.path;
      playbackDeviceProfile = "android-tv";
      playbackRecoveryStatePath = "/var/lib/ott-rs/state/client-api-playback-recovery.json";
    };

    web = {
      enable = true;
      bindAddress = "127.0.0.1";
      port = 8788;
      hostName = webHost;
      useACMEHost = "vaz.ovh";
      forceSSL = true;
      playbackDeviceProfile = "android-tv";
      playbackRecoveryStatePath = "/var/lib/ott-rs/state/web-playback-recovery.json";
      tailscaleAuth = {
        enable = true;
        trustedClientApi = true;
      };
    };

    internalApi = {
      enable = true;
      hostName = "ott-rs.pius.internal";
      allowedAddresses = [
        "100.103.78.39"
        "fd7a:115c:a1e0:ab12:4843:cd96:6267:4e27"
      ];
    };
  };

  systemd.services = {
    ott-rs = {
      unitConfig.OnSuccess = [ "ott-rs-health-sample.service" ];
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "5min";
      };
    };

    ott-rs-health-sample.serviceConfig.ExecStartPost = lib.mkAfter [
      # Confirm the fallback immediately after a catalog generation changes.
      priorityHealthSampleCommand
      priorityHealthSampleCommand
      "-${ottRs} health-plan --selection-input ${auditDir}/channel-selection.json --output ${healthDir}/health-plan.json --health-input ${healthDir}/health-state.json"
      "-${ottRs} health-status --stale-after-hours 36 --json --plan-input ${healthDir}/health-plan.json --state-input ${healthDir}/health-state.json --output ${healthDir}/health-status.json"
      "-${ottRs} doctor --stale-after-hours 36 --output ${auditDir}/doctor.json --state-file /var/lib/ott-rs/state/state.json --check-state-file /var/lib/ott-rs/state/check-state.json --source-inventory ${auditDir}/source-inventory.json --channel-selection ${auditDir}/channel-selection.json --health-sample ${healthDir}/health-priority-sample.json --health-state ${healthDir}/health-state.json --health-plan ${healthDir}/health-plan.json --health-status ${healthDir}/health-status.json --playlist /var/lib/ott-rs/private/playlist.m3u"
    ];
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/ott-rs";
      user = "ott-rs";
      group = "ott-rs";
      mode = "0700";
    }
  ];
}
