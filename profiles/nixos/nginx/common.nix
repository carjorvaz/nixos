{ lib, ... }:

{
  services.nginx = {
    enable = true;

    tailscaleAuth.expectedTailnet = lib.mkDefault "tail01b8d.ts.net";

    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    # For image uploads
    clientMaxBodySize = "1G";
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
