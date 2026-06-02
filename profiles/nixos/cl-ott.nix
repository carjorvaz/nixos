{
  self,
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.cl-ott;
  jellyfinUrl = "http://127.0.0.1:8096";
  jellyfinApiKeyFile = config.age.secrets.jellyfinClOttApiKey.path;
  jellyfinPlaylistPath =
    if cfg.healthSample.applyOutputPath != null then
      cfg.healthSample.applyOutputPath
    else
      cfg.outputPath;
  jellyfinFallbackPlaylistPath = cfg.outputPath;
  tunerName = "cl-ott";
  internalApiHost = "cl-ott.pius.internal";
  hadrianusTailscaleIPv4 = "100.103.78.39";
  hadrianusTailscaleIPv6 = "fd7a:115c:a1e0:ab12:4843:cd96:6267:4e27";

  ensureJellyfinTuner = pkgs.writeShellApplication {
    name = "cl-ott-jellyfin-ensure-tuner";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = ''
      api_key="$(tr -d '\r\n' < ${lib.escapeShellArg jellyfinApiKeyFile})"
      jellyfin_url=${lib.escapeShellArg jellyfinUrl}
      playlist=${lib.escapeShellArg jellyfinPlaylistPath}
      fallback_playlist=${lib.escapeShellArg jellyfinFallbackPlaylistPath}
      tuner_name=${lib.escapeShellArg tunerName}
      auth_header="X-Emby-Token: $api_key"

      if [ ! -e "$playlist" ]; then
        if [ -e "$fallback_playlist" ]; then
          echo "Playlist $playlist is not present yet; using $fallback_playlist for now"
          playlist="$fallback_playlist"
        else
          echo "Playlist $playlist is not present yet" >&2
          exit 0
        fi
      fi

      for attempt in $(seq 1 60); do
        if curl -fsS "$jellyfin_url/System/Info/Public" >/dev/null; then
          break
        fi
        if [ "$attempt" -eq 60 ]; then
          echo "Jellyfin did not become reachable at $jellyfin_url" >&2
          exit 1
        fi
        sleep 2
      done

      live_tv_config=""
      for attempt in $(seq 1 60); do
        if live_tv_config="$(curl -fsS -H "$auth_header" "$jellyfin_url/System/Configuration/LiveTv")"; then
          break
        fi
        if [ "$attempt" -eq 60 ]; then
          echo "Jellyfin Live TV configuration endpoint did not become ready" >&2
          exit 1
        fi
        sleep 2
      done
      exists="$(printf '%s' "$live_tv_config" \
        | jq -r --arg name "$tuner_name" --arg url "$playlist" \
          'any(.TunerHosts[]?; .Type == "m3u" and .FriendlyName == $name and .Url == $url)')"
      if [ "$exists" = "true" ]; then
        echo "Jellyfin tuner $tuner_name already points at $playlist"
        exit 0
      fi

      payload="$(mktemp)"
      trap 'rm -f "$payload"' EXIT
      printf '%s' "$live_tv_config" \
        | jq --arg name "$tuner_name" --arg url "$playlist" '
          (.TunerHosts // []) as $hosts
          | (
              $hosts
              | map(select(.Type == "m3u" and .FriendlyName == $name) | .Id)
              | map(select(. != null and . != ""))
              | first
            ) as $id
          | .TunerHosts = (
              ($hosts | map(select(.Type != "m3u" or .FriendlyName != $name)))
              + [{
                  Id: $id,
                  Type: "m3u",
                  FriendlyName: $name,
                  Url: $url,
                  TunerCount: 4,
                  AllowStreamSharing: true,
                  AllowHWTranscoding: true,
                  AllowFmp4TranscodingContainer: true,
                  FallbackMaxStreamingBitrate: 30000000,
                  EnableStreamLooping: false,
                  ImportFavoritesOnly: false,
                  IgnoreDts: false,
                  ReadAtNativeFramerate: false
                }]
            )
        ' > "$payload"

      curl -fsS -X POST -H "$auth_header" -H "Content-Type: application/json" \
        --data-binary "@$payload" "$jellyfin_url/System/Configuration/LiveTv" >/dev/null
      echo "Configured Jellyfin tuner $tuner_name for $playlist"
    '';
  };

  refreshJellyfinGuide = pkgs.writeShellApplication {
    name = "cl-ott-jellyfin-refresh-guide";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = ''
      api_key="$(tr -d '\r\n' < ${lib.escapeShellArg jellyfinApiKeyFile})"
      jellyfin_url=${lib.escapeShellArg jellyfinUrl}
      auth_header="X-Emby-Token: $api_key"

      scheduled_tasks=""
      for attempt in $(seq 1 60); do
        if scheduled_tasks="$(curl -fsS -H "$auth_header" "$jellyfin_url/ScheduledTasks")"; then
          break
        fi
        if [ "$attempt" -eq 60 ]; then
          echo "Jellyfin scheduled tasks endpoint did not become ready" >&2
          exit 1
        fi
        sleep 2
      done

      task_id="$(printf '%s' "$scheduled_tasks" \
        | jq -r '.[] | select(.Key == "RefreshGuide") | .Id' \
        | head -n 1)"
      if [ -z "$task_id" ] || [ "$task_id" = "null" ]; then
        echo "Could not find Jellyfin Refresh Guide scheduled task" >&2
        exit 1
      fi

      curl -fsS -X POST -H "$auth_header" \
        "$jellyfin_url/ScheduledTasks/Running/$task_id" >/dev/null
      echo "Started Jellyfin Refresh Guide task $task_id"
    '';
  };
in
{
  age.secrets.clOttTelegramEnv = {
    file = "${self}/secrets/clOttTelegramEnv.age";
    owner = "cl-ott";
    group = "cl-ott";
    mode = "0400";
  };

  age.secrets.clOttClientApiToken = {
    file = "${self}/secrets/clOttClientApiToken.age";
    owner = "cl-ott";
    group = "cl-ott";
    mode = "0400";
  };

  age.secrets.jellyfinClOttApiKey = {
    file = "${self}/secrets/jellyfinClOttApiKey.age";
    owner = "root";
    group = "root";
    mode = "0400";
  };

  services.cl-ott = {
    enable = true;
    environmentFile = config.age.secrets.clOttTelegramEnv.path;
    interval = "*-*-* 08:30:00";
    randomizedDelaySec = "30min";
    outputPath = "/persist/media/iptv/cl-ott.m3u";
    stateFile = "/var/lib/cl-ott/state.json";
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

  systemd.services.cl-ott-jellyfin-tuner = {
    description = "Ensure Jellyfin has the cl-ott M3U tuner";
    after = [ "jellyfin.service" ];
    wants = [ "jellyfin.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe ensureJellyfinTuner;
    };
  };

  systemd.services.cl-ott-jellyfin-refresh = {
    description = "Refresh Jellyfin guide after cl-ott playlist changes";
    after = [
      "jellyfin.service"
      "cl-ott-jellyfin-tuner.service"
    ];
    wants = [
      "jellyfin.service"
      "cl-ott-jellyfin-tuner.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe refreshJellyfinGuide;
    };
  };

  systemd.paths.cl-ott-jellyfin-refresh = {
    description = "Watch cl-ott playlist for Jellyfin refreshes";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = jellyfinPlaylistPath;
      Unit = "cl-ott-jellyfin-refresh.service";
    };
  };

  services.nginx.virtualHosts.${internalApiHost} = {
    extraConfig = ''
      allow ${hadrianusTailscaleIPv4};
      allow ${hadrianusTailscaleIPv6};
      deny all;

      server_tokens off;
      add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header Referrer-Policy "no-referrer" always;
      add_header Cache-Control "no-store" always;
    '';

    locations."/" = {
      return = "404";
    };

    locations."^~ /api/v1/" = {
      proxyPass = "http://127.0.0.1:${toString cfg.clientApi.port}";
      extraConfig = ''
        client_max_body_size 1k;

        proxy_connect_timeout 5s;
        proxy_read_timeout 20s;
        proxy_send_timeout 20s;
        proxy_buffering off;
        proxy_max_temp_file_size 0;
        proxy_set_header Authorization $http_authorization;

        if ($request_method !~ "^(GET|POST)$") {
          return 405;
        }

        if ($http_authorization !~ "^Bearer .+") {
          return 401;
        }
      '';
    };
  };
}
