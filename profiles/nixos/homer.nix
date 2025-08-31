{ ... }:

# Icons reference:
# - https://github.com/walkxcode/dashboard-icons/tree/main/svg
# - https://thehomelab.wiki/books/helpful-tools-resources/page/icons-for-self-hosted-dashboards
let
  domain = "vaz.ovh";
in
{
  imports = [ ./docker.nix ];

  virtualisation.oci-containers.containers.homer = {
    image = "b4bz/homer:latest";
    autoStart = true;
    ports = [ "127.0.0.1:8081:8080" ];
    volumes = [ "/var/lib/homer/assets:/www/assets" ];
    user = "1000:1000";
  };

  services.nginx.virtualHosts.${domain} = {
    forceSSL = true;
    useACMEHost = "vaz.ovh";
    locations."/".proxyPass = "http://127.0.0.1:8081";
  };

  environment.persistence."/persist".directories = [ "/var/lib/homer" ];
}
