{ lib, ... }:

{
  services.nginx = {
    enable = true;

    tailscaleAuth.expectedTailnet = lib.mkDefault "tail01b8d.ts.net";

    recommendedGzipSettings = true;
    recommendedBrotliSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    # For image uploads
    clientMaxBodySize = "1G";

    # /var/log/nginx is not persisted and root is rolled back on boot, so file
    # access logs vanish every reboot. The journal lives in /var/log/journal
    # (impermanence) and rotates under journald's 50M cap.
    commonHttpConfig = "access_log syslog:server=unix:/dev/log;";
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
}
