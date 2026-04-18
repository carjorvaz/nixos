{ config, lib, pkgs, ... }:

let
  domain = "sonarr.vaz.ovh";
  transmissionCategory = "tv-sonarr";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:8989";
    };

    sonarr.enable = true;

    homer.entries = [
      {
        name = "Sonarr";
        subtitle = "TV shows";
        url = "https://${domain}";
        logo = "/assets/icons/sonarr.svg";
        group = "arr";
      }
    ];
  };

  users.users.sonarr.extraGroups = [ "media" ];

  systemd.services.sonarr-configure-transmission = lib.mkIf (config.age.secrets ? sonarrApiKey) {
    description = "Ensure Sonarr uses a dedicated Transmission category";
    after = [
      "agenix.service"
      "sonarr.service"
      "transmission.service"
    ];
    wants = [
      "agenix.service"
      "transmission.service"
    ];
    wantedBy = [ "sonarr.service" ];
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

      api_key="$(<${config.age.secrets.sonarrApiKey.path})"
      base_url="http://127.0.0.1:8989"

      for _ in $(seq 1 30); do
        if curl -fsS -H "X-Api-Key: $api_key" "$base_url/api/v3/system/status" >/dev/null; then
          break
        fi
        sleep 2
      done

      client_id="$(
        curl -fsS -H "X-Api-Key: $api_key" "$base_url/api/v3/downloadclient" \
          | jq -r '.[] | select(.implementation == "Transmission") | .id' \
          | head -n1
      )"

      if [ -z "$client_id" ] || [ "$client_id" = "null" ]; then
        exit 0
      fi

      current="$(
        curl -fsS -H "X-Api-Key: $api_key" "$base_url/api/v3/downloadclient/$client_id"
      )"
      updated="$(
        printf '%s' "$current" \
          | jq --arg category "${transmissionCategory}" \
            '(.fields[] | select(.name == "tvCategory")).value = $category'
      )"

      if [ "$current" != "$updated" ]; then
        printf '%s' "$updated" \
          | curl -fsS -X PUT \
              -H "X-Api-Key: $api_key" \
              -H "Content-Type: application/json" \
              --data-binary @- \
              "$base_url/api/v3/downloadclient/$client_id" \
          >/dev/null
      fi
    '';
  };

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/sonarr"; user = "sonarr"; group = "sonarr"; }
  ];
}
