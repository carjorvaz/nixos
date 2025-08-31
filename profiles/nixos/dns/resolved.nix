{ lib, ... }:

{
  networking.nameservers = lib.mkDefault [ "9.9.9.9#dns.quad9.net" ];

  services.resolved = {
    enable = true;
    dnsovertls = "opportunistic";
    dnssec = "allow-downgrade";
    domains = [ "~." ];
  };
}
