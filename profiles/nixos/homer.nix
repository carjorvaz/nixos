{ ... }:

# Icons source: https://github.com/walkxcode/dashboard-icons
# Local copies in assets/homer-icons/, served at /assets/icons/.
let
  domain = "vaz.ovh";
in
{
  services.homer = {
    enable = true;
    virtualHost = {
      nginx.enable = true;
      inherit domain;
    };
    settings = {
      title = "vaz.ovh";
      columns = "auto";
      defaults.layout = "list";
    };
  };

  services.nginx = {
    tailscaleAuth = {
      enable = true;
      virtualHosts = [ domain ];
    };

    virtualHosts.${domain} = {
      default = true;
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/assets/icons/" = {
        alias = "${../../assets/homer-icons}/";
      };
    };
  };
}
