{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "sonarr.vaz.ovh";
in
{
  services = {
    nginx.virtualHosts.${domain} = {
      forceSSL = true;
      useACMEHost = "vaz.ovh";
      locations."/".proxyPass = "http://127.0.0.1:8989";
    };

    sonarr = {
      enable = true;
      user = "media";
    };
  };

  # TODO: remove when fixed
  # https://github.com/NixOS/nixpkgs/issues/360592#issuecomment-2513490613
  nixpkgs.config.permittedInsecurePackages = [
    "aspnetcore-runtime-6.0.36"
    "aspnetcore-runtime-wrapped-6.0.36"
    "dotnet-sdk-6.0.428"
    "dotnet-sdk-wrapped-6.0.428"
  ];

  environment.persistence."/persist".directories = [ "/var/lib/sonarr" ];
}
