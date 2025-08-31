{ ... }:

{
  services.nginx = {
    enable = true;

    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedZstdSettings = true;

    # For image uploads
    clientMaxBodySize = "1G";
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
