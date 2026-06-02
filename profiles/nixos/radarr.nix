{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "radarr.vaz.ovh";
  transmissionCategory = "movies-radarr";
in
{
  services = {
    nginx = {
      tailscaleAuth = {
        enable = true;
        virtualHosts = [ domain ];
      };

      virtualHosts.${domain} = {
        forceSSL = true;
        useACMEHost = "vaz.ovh";
        locations."/".proxyPass = "http://127.0.0.1:7878";
      };
    };

    radarr.enable = true;

    homer.entries = [
      {
        name = "Radarr";
        subtitle = "Movies";
        url = "https://${domain}";
        logo = "/assets/icons/radarr.svg";
        group = "arr";
      }
    ];
  };

  users.users.radarr.extraGroups = [ "media" ];

  systemd.services.radarr.serviceConfig.UMask = lib.mkForce "0002";

  systemd.services.radarr-configure-transmission = lib.mkIf (config.age.secrets ? radarrApiKey) {
    description = "Ensure Radarr uses a dedicated Transmission category";
    after = [
      "agenix.service"
      "radarr.service"
      "transmission.service"
    ];
    wants = [
      "agenix.service"
      "transmission.service"
    ];
    wantedBy = [ "radarr.service" ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = 120;
    };
    path = with pkgs; [
      coreutils
      curl
      gnused
      jq
    ];
    script = ''
      set -euo pipefail

      api_key="$(<${config.age.secrets.radarrApiKey.path})"
      base_url="http://127.0.0.1:7878"

      radarr_get() {
        endpoint="$1"
        label="$2"
        response=""
        for attempt in $(seq 1 60); do
          if response="$(curl -fsS -H "X-Api-Key: $api_key" "$base_url$endpoint")"; then
            printf '%s' "$response"
            return 0
          fi
          if [ "$attempt" -eq 60 ]; then
            echo "$label did not become ready" >&2
            return 1
          fi
          sleep 2
        done
      }

      radarr_put() {
        endpoint="$1"
        label="$2"
        payload="$3"
        for attempt in $(seq 1 60); do
          if printf '%s' "$payload" \
            | curl -fsS -X PUT \
              -H "X-Api-Key: $api_key" \
              -H "Content-Type: application/json" \
              --data-binary @- \
              "$base_url$endpoint" \
            >/dev/null; then
            return 0
          fi
          if [ "$attempt" -eq 60 ]; then
            echo "$label did not accept update" >&2
            return 1
          fi
          sleep 2
        done
      }

      radarr_get "/api/v3/system/status" "Radarr system status" >/dev/null

      client_id="$(
        radarr_get "/api/v3/downloadclient" "Radarr download clients" \
          | jq -r '.[] | select(.implementation == "Transmission") | .id' \
          | head -n1
      )"

      if [ -z "$client_id" ] || [ "$client_id" = "null" ]; then
        exit 0
      fi

      current="$(
        radarr_get "/api/v3/downloadclient/$client_id" "Radarr download client $client_id"
      )"
      updated="$(
        printf '%s' "$current" \
          | jq --arg category "${transmissionCategory}" \
            '(.fields[] | select(.name == "movieCategory")).value = $category'
      )"

      if [ "$current" != "$updated" ]; then
        radarr_put "/api/v3/downloadclient/$client_id" "Radarr download client $client_id" "$updated"
      fi
    '';
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/radarr";
      user = "radarr";
      group = "radarr";
    }
  ];
}
