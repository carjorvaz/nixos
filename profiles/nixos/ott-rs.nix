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
  # switch-to-configuration-ng starts changed services from the previously
  # loaded unit; a service-side hook cannot call systemctl (unprivileged), so an
  # activation script schedules a short-lived root oneshot that compares the new
  # unit's ExecStart arguments with the running argv and restarts on mismatch.
  servingParityScript = pkgs.writeShellScript "ott-rs-serving-parity" ''
    export PATH=/run/current-system/sw/bin:/run/current-system/sw/sbin:$PATH
    for unit in ott-rs-client-api.service ott-rs-web.service; do
      current=$(readlink -f "/run/current-system/etc/systemd/system/$unit" 2>/dev/null) || continue
      want_cmd=$(sed -n "s/^ExecStart=//p" "$current" | head -n 1)
      [ -n "$want_cmd" ] || continue
      pid=$(/run/current-system/sw/bin/systemctl show -p MainPID --value "$unit" 2>/dev/null) || continue
      [ -n "$pid" ] && [ "$pid" != 0 ] || continue
      want_args=$(printf "%s" "$want_cmd" | cut -d" " -f2-)
      have_args=$(tr "\0" " " < "/proc/$pid/cmdline" | cut -d" " -f2-)
      [ "$want_args" = "$have_args" ] && continue
      /run/current-system/sw/bin/logger -t ott-rs-serving-parity "restarting $unit: running command differs from the new unit" || true
      /run/current-system/sw/bin/systemctl restart "$unit" || true
    done
  '';

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

  system.activationScripts.ott-rs-serving-parity = {
    deps = [ "etc" ];
    text = ''
      ${config.systemd.package}/bin/systemd-run --on-active=30 --unit=ott-rs-serving-parity --collect ${servingParityScript}
    '';
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
