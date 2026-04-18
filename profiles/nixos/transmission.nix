{ config, pkgs, ... }:

let
  domain = "transmission.vaz.ovh";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass =
        "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}";
    };

    transmission = {
      enable = true;
      package = pkgs.transmission_4;
      openFirewall = true;
      openPeerPorts = true;
      webHome = pkgs.flood-for-transmission;
      # Reference: https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md
      settings = {
        download-dir = "/persist/media/downloads";
        umask = "002";
        rpc-whitelist-enabled = true;
        rpc-whitelist = "127.0.0.1,100.64.*.*";
        rpc-host-whitelist-enabled = true;
        rpc-host-whitelist = "*.vaz.ovh,*.rome.vaz.ovh";
      };
    };

    homer.entries = [
      {
        name = "Transmission";
        subtitle = "Downloads";
        url = "https://${domain}";
        logo = "/assets/icons/transmission.svg";
        group = "arr";
      }
    ];
  };

  users.users.transmission.extraGroups = [ "media" ];

  systemd.tmpfiles.rules = [
    # Keep Arr-managed torrents segregated from unrelated/manual downloads.
    "d /persist/media/downloads/movies-radarr 2775 root media -"
    "d /persist/media/downloads/tv-sonarr     2775 root media -"
  ];

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/transmission"; user = "transmission"; group = "transmission"; }
  ];
}
