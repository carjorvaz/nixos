{
  self,
  config,
  ...
}:

let
  webHost = "ott-web.vaz.ovh";
  legacyWebHost = "cl-ott-web.vaz.ovh";
in
{
  age.secrets = {
    clOttTelegramEnv = {
      file = "${self}/secrets/clOttTelegramEnv.age";
      owner = "ott-rs";
      group = "ott-rs";
      mode = "0400";
    };

    clOttClientApiToken = {
      file = "${self}/secrets/clOttClientApiToken.age";
      owner = "ott-rs";
      group = "ott-rs";
      mode = "0400";
    };
  };

  services.ott-rs = {
    enable = true;
    environmentFile = config.age.secrets.clOttTelegramEnv.path;
    interval = "*-*-* 08:30:00";
    randomizedDelaySec = "30min";
    force = true;
    telegram.enable = true;

    outputPath = null;
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

    doctor = {
      enable = true;
      outputPath = "/var/lib/ott-rs/audit/doctor.json";
      staleAfterHours = 36;
    };

    clientApi = {
      enable = true;
      bindAddress = "127.0.0.1";
      port = 8787;
      tokenFile = config.age.secrets.clOttClientApiToken.path;
    };

    web = {
      enable = true;
      bindAddress = "127.0.0.1";
      port = 8788;
      hostName = webHost;
      useACMEHost = "vaz.ovh";
      forceSSL = true;
      tailscaleAuth = {
        enable = true;
        trustedClientApi = true;
      };
    };

    internalApi = {
      enable = true;
      hostName = "cl-ott.pius.internal";
      allowedAddresses = [
        "100.103.78.39"
        "fd7a:115c:a1e0:ab12:4843:cd96:6267:4e27"
      ];
    };
  };

  services.nginx.virtualHosts.${legacyWebHost} = {
    forceSSL = true;
    useACMEHost = "vaz.ovh";
    globalRedirect = webHost;
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
