{ config, lib, pkgs, ... }:

let domain = "changedetection.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass =
        "http://127.0.0.1:${toString config.services.changedetection-io.port}";
    };

    changedetection-io = {
      enable = true;
      behindProxy = true;
      baseURL = "https://${domain}";
      webDriverSupport = true;
      # environmentFile
      # playwrightSupport = true;
    };
  };

  environment.persistence."/persist".directories =
    [ "/var/lib/changedetection-io" ];
}
