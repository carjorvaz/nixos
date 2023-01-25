{ config, lib, pkgs, ... }:

let domain = "readarr.vaz.ovh";
in {
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:8787";
    };

    # Copied from: https://github.com/NixOS/nixpkgs/pull/203487
    readarr = {
      enable = true;
      user = "media";
    };
  };

  environment.persistence."/persist".directories = [ "/var/lib/readarr" ];
}
