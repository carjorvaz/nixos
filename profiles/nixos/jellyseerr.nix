{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "jellyseerr.vaz.ovh";
  publicDomain = "jellyseerr.vaz.one";
  # Jellyseerr is an internal API client; the Arr vhosts require interactive
  # Tailscale auth and reject pius's tagged node identity.
  arrServerName = "Pius";
  internalArrTargets = {
    radarr = {
      hostname = "127.0.0.1";
      port = 7878;
      useSsl = false;
      baseUrl = "";
    };
    sonarr = {
      hostname = "127.0.0.1";
      port = 8989;
      useSsl = false;
      baseUrl = "";
    };
  };
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
        locations."/".proxyPass = "http://127.0.0.1:${toString config.services.seerr.port}";
      };
    };

    seerr.enable = true;

    homer.entries = [
      {
        name = "Jellyseerr";
        subtitle = "Media requests";
        url = "https://${domain}";
        logo = "/assets/icons/jellyseerr.svg";
        group = "media";
      }
    ];
  };

  systemd.services.seerr = {
    path = [
      pkgs.coreutils
      pkgs.jq
    ];
    preStart = lib.mkBefore ''
      settings=${config.services.seerr.configDir}/settings.json
      if [ -f "$settings" ]; then
        tmp="$(mktemp)"
        jq --arg applicationUrl "https://${publicDomain}" \
          --arg arrServerName "${arrServerName}" \
          --argjson internalArrTargets '${builtins.toJSON internalArrTargets}' \
          '.main.applicationUrl = $applicationUrl
          | if (.radarr | type) == "array" then
              .radarr |= map(
                if .name == $arrServerName then
                  . + $internalArrTargets.radarr
                else . end
              )
            else . end
          | if (.sonarr | type) == "array" then
              .sonarr |= map(
                if .name == $arrServerName then
                  . + $internalArrTargets.sonarr
                else . end
              )
            else . end' \
          "$settings" > "$tmp"
        cat "$tmp" > "$settings"
        rm -f "$tmp"
      fi
    '';
  };

  environment.persistence."/persist".directories = [ "/var/lib/private/jellyseerr" ];
}
