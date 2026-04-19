{ ... }:

let
  domain = "audiobookshelf.vaz.ovh";
  port = 8000;
in
{
  services = {
    audiobookshelf = {
      enable = true;
      host = "127.0.0.1";
      inherit port;
    };

    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."= /".return = "302 /audiobookshelf/";
      locations."/".proxyPass = "http://127.0.0.1:${toString port}";
      locations."/".proxyWebsockets = true;
      locations."/".recommendedProxySettings = true;
    };

    homer.entries = [
      {
        name = "Audiobookshelf";
        subtitle = "Audiobooks";
        url = "https://${domain}/audiobookshelf/";
        group = "media";
      }
    ];
  };

  users.users.audiobookshelf.extraGroups = [ "media" ];

  systemd.tmpfiles.rules = [
    # Audiobooks are managed separately from the Calibre/CWA ebook library.
    "d /persist/media/audiobooks 2775 root media -"
  ];

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/audiobookshelf";
      user = "audiobookshelf";
      group = "audiobookshelf";
    }
  ];
}
