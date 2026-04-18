{
  self,
  config,
  lib,
  ...
}:

{
  age.secrets.radarrApiKey = {
    file = "${self}/secrets/radarrApiKey.age";
    owner = "recyclarr";
  };
  age.secrets.sonarrApiKey = {
    file = "${self}/secrets/sonarrApiKey.age";
    owner = "recyclarr";
  };

  services.recyclarr = {
    enable = true;
    # schedule = "daily"; # default

    configuration = {
      # SQP-1: 4K preferred, 1080p/720p fallback — includes Bluray + WEB
      radarr."sqp-1-2160p" = {
        base_url = "http://localhost:7878";
        api_key._secret = config.age.secrets.radarrApiKey.path;

        # Override the template profile: accept anything above CAM/TS,
        # prefer 4K, fall back through 1080p → 720p → DVD → 480p → SDTV.
        # min_format_score=0 so low-quality releases aren't blocked by
        # custom format scoring (public indexers score low).
        quality_profiles = [
          {
            name = "SQP-1 (2160p)";
            min_format_score = 0;
            qualities = [
              { name = "Bluray-2160p"; }
              {
                name = "WEB 2160p";
                qualities = [ "WEBDL-2160p" "WEBRip-2160p" ];
              }
              {
                name = "Bluray|WEB-1080p";
                qualities = [ "Bluray-1080p" "WEBDL-1080p" "WEBRip-1080p" ];
              }
              {
                name = "WEB|Bluray-720p";
                qualities = [ "WEBDL-720p" "WEBRip-720p" "Bluray-720p" ];
              }
              { name = "HDTV-1080p"; }
              { name = "HDTV-720p"; }
              { name = "DVD"; }
              {
                name = "WEB 480p";
                qualities = [ "WEBDL-480p" "WEBRip-480p" ];
              }
              { name = "SDTV"; }
            ];
          }
        ];

        include = [
          { template = "radarr-quality-definition-sqp-streaming"; }
          { template = "radarr-quality-profile-sqp-1-2160p-default"; }
          { template = "radarr-custom-formats-sqp-1-2160p"; }
        ];
      };

      # WEB-2160p: 4K WEB preferred, full fallback to SDTV
      sonarr."web-2160p-v4" = {
        base_url = "http://localhost:8989";
        api_key._secret = config.age.secrets.sonarrApiKey.path;

        quality_profiles = [
          {
            name = "WEB-2160p";
            qualities = [
              {
                name = "WEB 2160p";
                qualities = [ "WEBDL-2160p" "WEBRip-2160p" ];
              }
              {
                name = "WEB 1080p";
                qualities = [ "WEBDL-1080p" "WEBRip-1080p" ];
              }
              { name = "Bluray-2160p"; }
              { name = "Bluray-1080p"; }
              { name = "HDTV-1080p"; }
              {
                name = "WEB 720p";
                qualities = [ "WEBDL-720p" "WEBRip-720p" ];
              }
              { name = "Bluray-720p"; }
              { name = "HDTV-720p"; }
              { name = "DVD"; }
              {
                name = "WEB 480p";
                qualities = [ "WEBDL-480p" "WEBRip-480p" ];
              }
              { name = "SDTV"; }
            ];
          }
        ];

        include = [
          { template = "sonarr-quality-definition-series"; }
          { template = "sonarr-v4-quality-profile-web-2160p-alternative"; }
          { template = "sonarr-v4-custom-formats-web-2160p"; }
        ];
      };
    };
  };

  systemd.services.recyclarr = {
    serviceConfig = {
      # The generated config contains live API keys after secret substitution.
      UMask = "0077";
      StateDirectoryMode = "0700";
    };

    preStart = lib.mkAfter ''
      chmod 0700 /var/lib/recyclarr
      chmod 0600 /var/lib/recyclarr/config.json
    '';
  };

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/recyclarr"; user = "recyclarr"; group = "recyclarr"; }
  ];
}
