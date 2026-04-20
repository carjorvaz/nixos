{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "jellyseerr.vaz.ovh";
  publicDomain = "jellyseerr.vaz.one";
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
        locations."/".proxyPass = "http://127.0.0.1:${toString config.services.jellyseerr.port}";
      };
    };

    jellyseerr.enable = true;

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

  systemd.services.jellyseerr = {
    path = [ pkgs.coreutils pkgs.jq ];
    preStart = lib.mkBefore ''
      settings=/var/lib/jellyseerr/config/settings.json
      if [ -f "$settings" ]; then
        tmp="$(mktemp)"
        jq --arg applicationUrl "https://${publicDomain}" \
          '.main.applicationUrl = $applicationUrl' \
          "$settings" > "$tmp"
        cat "$tmp" > "$settings"
        rm -f "$tmp"
      fi
    '';
  };

  environment.persistence."/persist".directories = [ "/var/lib/private/jellyseerr" ];
}
