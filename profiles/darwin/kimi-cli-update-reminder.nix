{
  pkgs,
  inputs,
  lib,
  ...
}:

let
  jobName = "kimi-cli-update-reminder";
  repoDir = "/Users/cjv/Documents/nixos";
  kimiCliPackage = inputs.kimi-cli.packages.${pkgs.stdenv.hostPlatform.system}.kimi-cli;
  currentVersion = kimiCliPackage.version;
  updateCommand = "cd ${repoDir} && nix flake update kimi-cli && darwin-rebuild switch --flake ${repoDir}#air";
  latestVersionUrl = "https://cdn.kimi.com/binaries/kimi-cli/latest";

  reminderScript = pkgs.writeShellApplication {
    name = jobName;
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      kimiCliPackage
    ];
    text = ''
      set -eu

      cache_dir="$HOME/Library/Caches/${jobName}"
      state_file="$cache_dir/last-notified-version"
      mkdir -p "$cache_dir"

      current_version=${lib.escapeShellArg currentVersion}

      latest_version="$(curl --fail --silent --show-error --location --max-time 15 ${lib.escapeShellArg latestVersionUrl} || true)"
      latest_version="$(printf '%s' "$latest_version" | tr -d '[:space:]')"
      if [ -z "$latest_version" ]; then
        echo "${jobName}: failed to determine latest version"
        exit 0
      fi

      newest_version="$(printf '%s\n%s\n' "$current_version" "$latest_version" | sort -V | tail -n 1)"
      if [ "$newest_version" = "$current_version" ]; then
        rm -f "$state_file"
        exit 0
      fi

      if [ -f "$state_file" ] && [ "$(cat "$state_file")" = "$latest_version" ]; then
        exit 0
      fi

      printf '%s' "$latest_version" > "$state_file"

      echo "${jobName}: installed $current_version, latest $latest_version"
      echo "${jobName}: update with: ${updateCommand}"

      /usr/bin/osascript - \
        "Kimi CLI update available" \
        "Installed $current_version, latest $latest_version" \
        "Run in ${repoDir}: nix flake update kimi-cli" <<'APPLESCRIPT'
on run argv
  display notification (item 3 of argv) with title (item 1 of argv) subtitle (item 2 of argv)
end run
APPLESCRIPT
    '';
  };
in
{
  launchd.user.agents."${jobName}" = {
    environment.HOME = "/Users/cjv";
    command = "${reminderScript}/bin/${jobName}";
    serviceConfig = {
      ProcessType = "Background";
      RunAtLoad = true;
      StartInterval = 86400;
      WorkingDirectory = "/Users/cjv";
      StandardOutPath = "/Users/cjv/Library/Logs/${jobName}.log";
      StandardErrorPath = "/Users/cjv/Library/Logs/${jobName}.log";
    };
  };
}
