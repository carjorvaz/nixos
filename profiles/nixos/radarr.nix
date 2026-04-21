{ config, lib, pkgs, ... }:

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
            '(.fields[] | select(.name == "movieCategory")).value = $category'
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
    { directory = "/var/lib/radarr"; user = "radarr"; group = "radarr"; }
  ];
}
