{
  self,
  config,
  ...
}:

{
  age.secrets = {
    clOttTelegramEnv = {
      file = "${self}/secrets/clOttTelegramEnv.age";
      owner = "cl-ott";
      group = "cl-ott";
      mode = "0400";
    };

    clOttClientApiToken = {
      file = "${self}/secrets/clOttClientApiToken.age";
      owner = "cl-ott";
      group = "cl-ott";
      mode = "0400";
    };

    jellyfinClOttApiKey = {
      file = "${self}/secrets/jellyfinClOttApiKey.age";
      owner = "root";
      group = "root";
      mode = "0400";
    };
  };

  services.cl-ott = {
    enable = true;
    environmentFile = config.age.secrets.clOttTelegramEnv.path;
    interval = "*-*-* 08:30:00";
    randomizedDelaySec = "30min";
    outputPath = "/persist/media/iptv/cl-ott.m3u";
    stateFile = "/var/lib/cl-ott/state.json";
    force = true;
    outputGroup = "media";
    searchLimit = 50;

    guide = {
      outputPath = "/var/lib/cl-ott/guide.json";
      xmltvUrl = "https://github.com/LITUATUI/M3UPT/raw/main/EPG/epg-m3upt.xml.xz";
    };

    clientApi = {
      enable = true;
      bindAddress = "127.0.0.1";
      port = 8787;
      tokenFile = config.age.secrets.clOttClientApiToken.path;
    };

    web = {
      enable = true;
      hostName = "cl-ott-web.vaz.ovh";
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

    jellyfin = {
      enable = true;
      url = "http://127.0.0.1:8096";
      apiKeyFile = config.age.secrets.jellyfinClOttApiKey.path;
      tunerName = "cl-ott";
      playlistPath = "/persist/media/iptv/cl-ott-health.m3u";
      fallbackPlaylistPath = "/persist/media/iptv/cl-ott.m3u";
      serviceName = "jellyfin.service";
      refreshGuideOnChange = true;
    };

    healthSample = {
      enable = true;
      interval = "*-*-* 09:30:00";
      randomizedDelaySec = "15min";
      outputPath = "/var/lib/cl-ott/health.json";
      statusPath = "/var/lib/cl-ott/health-status.json";
      applyOutputPath = "/persist/media/iptv/cl-ott-health.m3u";
      applySummaryPath = "/var/lib/cl-ott/health-apply-summary.json";
      statusStaleAfterHours = 36;
      limit = 25;
      candidatesPerChannel = 2;
      timeout = 5;
      rotateDaily = true;
      selectedFailureThreshold = 2;
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/cl-ott";
      user = "cl-ott";
      group = "cl-ott";
      mode = "0700";
    }
  ];
}
