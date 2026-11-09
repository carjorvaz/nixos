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
  ottRsPackage = inputs.ott-rs.packages.${pkgs.system}.default;
  healthDir = "/var/lib/ott-rs/health";
  auditDir = "/var/lib/ott-rs/audit";
  healthStatePath = "${healthDir}/health-state.json";
  healthStateLockPath = "${healthDir}/health-state.lock";
  watchlistChannels = [
    "sport tv 1"
    "sport tv 2"
    "sport tv 3"
    "sport tv 4"
    "sport tv 5"
    "sport tv 6"
    "sport tv 7"
    "dazn 1"
    "pt - dazn 2"
    "dazn 3"
    "dazn 4"
    "dazn 5"
    "benfica tv"
    "rtp 1"
    "sic"
    "tvi"
  ];
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
    rankAuditPath = null;
    groupCatalogPath = null;

    guide.xmltvUrl = "https://github.com/LITUATUI/M3UPT/raw/main/EPG/epg-m3upt.xml.xz";

    health = {
      statePath = healthStatePath;
    };

    healthSample = {
      enable = true;
      stateInputPath = healthStatePath;
      stateOutputPath = healthStatePath;
      interval = "*-*-* *:00/30:00";
      randomizedDelaySec = "1m";
      unitStartTimeout = "20min";
      channels = watchlistChannels;
      extraArgs = [ "--state-lock" healthStateLockPath ];
      candidatesPerChannel = 3;
      selectedFailureThreshold = 2;
      replacementAliveThreshold = 2;
      timeoutSeconds = 8;
      forwardAllPlaybackHeaders = true;
      # readSeconds defaults to the deployed 6 s in module.nix.
    };

    doctor = {
      enable = false;
    };

    clientApi = {
      enable = true;
      bindAddress = "127.0.0.1";
      port = 8787;
      tokenFile = config.age.secrets.ottTvClientApiToken.path;
      playbackDeviceProfile = "android-tv";
      playbackRecoveryStatePath = "/var/lib/ott-rs/state/client-api-playback-recovery.json";
      forwardAllPlaybackHeaders = true;
      playbackDirectUpstreams = true;
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

  systemd = {
    services = {
      ott-rs = {
        unitConfig.OnSuccess = [ "ott-rs-health-sample.service" ];
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "5min";
        };
      };

    };
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
