{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "transmission.vaz.ovh";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:${toString config.services.transmission.settings.rpc-port}";
    };

    transmission = {
      enable = true;
      user = "media";
      openFirewall = true;
      openPeerPorts = true;
      webHome = pkgs.flood-for-transmission;
      # Reference: https://github.com/transmission/transmission/blob/main/docs/Editing-Configuration-Files.md
      settings = {
        download-dir = "/persist/media/downloads";
        rpc-whitelist-enabled = true;
        rpc-whitelist = "127.0.0.1,100.64.*.*";
        rpc-host-whitelist-enabled = true;
        rpc-host-whitelist = "*.vaz.ovh,*.rome.vaz.ovh";
      };
    };
  };

  environment.persistence."/persist".directories = [ "/var/lib/transmission" ];
}
