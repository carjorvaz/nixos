{ pkgs, ... }:

let
  domain = "jellyfin.vaz.ovh";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/" = {
        proxyPass = "http://127.0.0.1:8096";
        proxyWebsockets = true;
      };
    };

    jellyfin.enable = true;

    homer.entries = [
      {
        name = "Jellyfin";
        subtitle = "Media streaming";
        url = "https://${domain}";
        logo = "/assets/icons/jellyfin.svg";
        group = "media";
      }
    ];
  };

  users.groups.media = { };

  users.users.jellyfin.extraGroups = [
    "media"
    "render"
    "video"
  ];

  systemd.tmpfiles.rules = [
    "d /persist/media               2775 root media -"
    "d /persist/media/downloads     2775 root media -"
    "d /persist/media/books         2775 root media -"
    "d /persist/media/movies        2775 root media -"
    "d /persist/media/tv            2775 root media -"
    "d /persist/media/documentaries 2775 root media -"
  ];

  environment.systemPackages = with pkgs; [
    jellyfin-ffmpeg
  ];

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/jellyfin"; user = "jellyfin"; group = "jellyfin"; }
  ];
}
