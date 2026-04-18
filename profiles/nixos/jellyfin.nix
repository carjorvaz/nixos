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

  # Jellyfin's dynamic image generation needs actual fonts available even on
  # headless servers; without them, collection/poster collage rendering throws.
  fonts = {
    fontconfig.enable = true;
    packages = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
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

  systemd.services.jellyfin = {
    environment = {
      FONTCONFIG_FILE = "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
      FONTCONFIG_PATH = "${pkgs.fontconfig.out}/etc/fonts";
      XDG_CACHE_HOME = "/var/cache/jellyfin";
    };

    serviceConfig = {
      CacheDirectory = "jellyfin";
    };
  };

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/jellyfin"; user = "jellyfin"; group = "jellyfin"; }
  ];
}
