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
  tunerName = "cl-ott";

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
      playlist=${lib.escapeShellArg cfg.outputPath}
      tuner_name=${lib.escapeShellArg tunerName}
      auth_header="X-Emby-Token: $api_key"

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

      live_tv_config="$(curl -fsS -H "$auth_header" "$jellyfin_url/System/Configuration/LiveTv")"
      stale_ids="$(printf '%s' "$live_tv_config" \
        | jq -r --arg name "$tuner_name" --arg url "$playlist" \
          '.TunerHosts[]? | select(.Type == "m3u" and .FriendlyName == $name and .Url != $url) | .Id')"
      for id in $stale_ids; do
        curl -fsS -X DELETE -H "$auth_header" "$jellyfin_url/LiveTv/TunerHosts?id=$id" >/dev/null
        echo "Removed stale Jellyfin tuner $id for $tuner_name"
      done

      live_tv_config="$(curl -fsS -H "$auth_header" "$jellyfin_url/System/Configuration/LiveTv")"
      exists="$(printf '%s' "$live_tv_config" \
        | jq -r --arg name "$tuner_name" --arg url "$playlist" \
          'any(.TunerHosts[]?; .Type == "m3u" and .FriendlyName == $name and .Url == $url)')"
      if [ "$exists" = "true" ]; then
        echo "Jellyfin tuner $tuner_name already points at $playlist"
        exit 0
      fi

      payload="$(mktemp)"
      trap 'rm -f "$payload"' EXIT
      jq -n --arg name "$tuner_name" --arg url "$playlist" '{
        Type: "m3u",
        FriendlyName: $name,
        Url: $url,
        TunerCount: 4,
        AllowStreamSharing: true,
        AllowHWTranscoding: true,
        AllowFmp4TranscodingContainer: true,
        EnableStreamLooping: false,
        ImportFavoritesOnly: false,
        IgnoreDts: false,
        ReadAtNativeFramerate: false
      }' > "$payload"

      curl -fsS -X POST -H "$auth_header" -H "Content-Type: application/json" \
        --data-binary "@$payload" "$jellyfin_url/LiveTv/TunerHosts" >/dev/null
      echo "Added Jellyfin tuner $tuner_name for $playlist"
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

      task_id="$(curl -fsS -H "$auth_header" "$jellyfin_url/ScheduledTasks" \
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
      PathChanged = cfg.outputPath;
      Unit = "cl-ott-jellyfin-refresh.service";
    };
  };
}
