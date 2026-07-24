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
  healthStatePath = "${healthDir}/health-state.json";
  broadHealthStatePath = "${healthDir}/health-broad-state.json";
  priorityHealthStatePath = "${healthDir}/health-priority-sport-tv-5-state.json";
  priorityHealthSampleCommand = "${ottRs} health-sample --input ${auditDir}/channel-selection.json --output ${healthDir}/health-priority-sample.json --state-input ${priorityHealthStatePath} --state-output ${priorityHealthStatePath} --limit 1 --offset 0 --strategy focus --channel-exact 'sport tv 5' --candidates-per-channel 5 --selected-failure-threshold 2 --replacement-alive-threshold 2 --timeout 8 --read-seconds 6";
  mergeHealthStates = pkgs.writeShellApplication {
    name = "ott-rs-merge-health-states";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.util-linux
    ];
    text = ''
      exec 9>"${healthDir}/health-state-merge.lock"
      flock 9

      empty_input="$(mktemp "${healthDir}/.empty-health-state.XXXXXX")"
      output="$(mktemp "${healthDir}/.health-state.XXXXXX")"
      trap 'rm -f "$empty_input" "$output"' EXIT
      printf 'null\n' > "$empty_input"

      broad_input="${broadHealthStatePath}"
      priority_input="${priorityHealthStatePath}"
      [[ -r "$broad_input" ]] || broad_input="$empty_input"
      [[ -r "$priority_input" ]] || priority_input="$empty_input"
      generation="$(jq -r '.generated_at_universal_time' "${auditDir}/channel-selection.json")"

      jq -n \
        --argjson generation "$generation" \
        --slurpfile broad "$broad_input" \
        --slurpfile priority "$priority_input" '
          def current($state):
            if ($state | type) == "object"
              and $state.selection_generated_at_universal_time == $generation
            then $state
            else null
            end;
          current($broad[0] // null) as $b
          | current($priority[0] // null) as $p
          | if $b == null and $p == null then empty
            else
              ($b // $p) as $base
              | (reduce ((($b.channels // []) + ($p.channels // []))[]) as $channel
                  ({}; .[$channel.canonical_name] = $channel)
                | [.[]]
                | sort_by(.canonical_name)) as $channels
              | $base
              | .format_version = 1
              | .kind = "health-state"
              | .contains_stream_urls = "no"
              | .selection_generated_at_universal_time = $generation
              | .checked_at_universal_time = ([
                  $b.checked_at_universal_time,
                  $p.checked_at_universal_time
                ] | map(select(. != null)) | max)
              | .updated_at_universal_time = ([
                  $b.updated_at_universal_time,
                  $p.updated_at_universal_time
                ] | map(select(. != null)) | max)
              | .samples_merged = ([
                  $b.samples_merged,
                  $p.samples_merged
                ] | map(select(. != null)) | add)
              | .channels_available = ([
                  $b.channels_available,
                  $p.channels_available
                ] | map(select(. != null)) | max)
              | .channels = $channels
              | .channels_seen = ($channels | length)
              | .candidates_seen = ([$channels[].candidates[]] | length)
              | .candidates_alive = ([
                  $channels[].candidates[]
                  | select(.alive_status == "alive")
                ] | length)
              | .candidates_failed = ([
                  $channels[].candidates[]
                  | select(.alive_status == "failed")
                ] | length)
              | .channels_with_alive_candidate = ([
                  $channels[]
                  | select(any(.candidates[]; .alive_status == "alive"))
                ] | length)
              | .channels_with_selected_alive = ([
                  $channels[]
                  | select(any(.candidates[];
                      .candidate_index == 0 and .alive_status == "alive"))
                ] | length)
            end
        ' > "$output"

      if [[ -s "$output" ]]; then
        chmod 0640 "$output"
        mv -f "$output" "${healthStatePath}"
      fi
    '';
  };
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
      statePath = healthStatePath;
      planPath = "/var/lib/ott-rs/health/health-plan.json";
      statusPath = "/var/lib/ott-rs/health/health-status.json";
      staleAfterHours = 36;
    };

    healthSample = {
      enable = true;
      stateInputPath = broadHealthStatePath;
      stateOutputPath = broadHealthStatePath;
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
      unitConfig.OnSuccess = [
        "ott-rs-health-sample.service"
        "ott-rs-health-priority.service"
      ];
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "5min";
      };
    };

    ott-rs-health-sample.serviceConfig.ExecStartPost = lib.mkBefore [
      "${mergeHealthStates}/bin/ott-rs-merge-health-states"
    ];

    ott-rs-health-priority = {
      description = "Confirm priority ott-rs playback health";
      after = [
        "network-online.target"
        "ott-rs.service"
      ];
      wants = [ "network-online.target" ];
      path = [ config.services.ott-rs.ffmpegPackage ];
      unitConfig.ConditionPathExists = "${auditDir}/channel-selection.json";
      serviceConfig = {
        Type = "oneshot";
        User = "ott-rs";
        Group = "ott-rs";
        UMask = "0027";
        StateDirectory = "ott-rs";
        StateDirectoryMode = "0700";
        ReadWritePaths = [ healthDir ];
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_INET"
          "AF_INET6"
        ];
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
      };
      script = ''
        # Two observations satisfy the replacement threshold.
        ${priorityHealthSampleCommand}
        ${priorityHealthSampleCommand}
        ${mergeHealthStates}/bin/ott-rs-merge-health-states
      '';
    };
  };

  systemd.timers.ott-rs-health-priority = {
    description = "Refresh priority ott-rs playback health";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:00/4:00";
      Persistent = true;
      RandomizedDelaySec = "30s";
      Unit = "ott-rs-health-priority.service";
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
