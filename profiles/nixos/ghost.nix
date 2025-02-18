{
  config,
  lib,
  pkgs,
  ...
}:

let
  port = 3001;
in
{
  services.nginx.virtualHosts."mafaldaribeiro.com" = {
    forceSSL = true;
    enableACME = true;
    locations."/".proxyPass = "http://127.0.0.1:${toString port}";
  };

  virtualisation.podman.defaultNetwork.settings.dns_enabled = true;

  virtualisation.oci-containers.containers = {
    "ghost-mafalda" = {
      # Keep up-to-date
      # Instructions at https://hub.docker.com/_/ghost
      # Must upgrade to latest minor version before upgrading major version
      # or database issues will occur
      image = "ghost:5.109.6";
      autoStart = true;
      ports = [ "${toString port}:2368" ];

      environment = {
        url = "https://mafaldaribeiro.com";

        database__client = "mysql";
        database__connection__host = "db-mafalda";
        database__connection__user = "root";
        database__connection__password = "example";
        database__connection__database = "ghost";
      };

      dependsOn = [ "db-mafalda" ];

      volumes = [ "/persist/mafalda/ghost:/var/lib/ghost/content" ];
    };

    "db-mafalda" = {
      image = "mysql:8.0";
      autoStart = true;

      environment = {
        MYSQL_ROOT_PASSWORD = "example";
      };

      volumes = [ "/persist/mafalda/db:/var/lib/mysql" ];
    };
  };
}
