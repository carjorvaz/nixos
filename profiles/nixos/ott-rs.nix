{
  self,
  config,
  ...
}:

let
  webHost = "ott-web.vaz.ovh";
  telegramSecretGroup = "telegram-secrets";
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
    environmentFile = config.age.secrets.piusTelegramEnv.path;
    interval = "*-*-* 08:30:00";
    randomizedDelaySec = "30min";
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
      candidatesPerChannel = 2;
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

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/ott-rs";
      user = "ott-rs";
      group = "ott-rs";
      mode = "0700";
    }
  ];
}
