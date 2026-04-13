{ lib, ... }:

{
  networking.nameservers = lib.mkDefault [ "9.9.9.9#dns.quad9.net" ];

  services.resolved = {
    enable = true;
    settings.Resolve = {
      DNSOverTLS = "opportunistic";
      DNSSEC = "allow-downgrade";
      LLMNR = false;
      Domains = [ "~." ];
    };
  };

  # Don't restart resolved during nixos-rebuild switch to avoid DNS gaps.
  systemd.services.systemd-resolved.stopIfChanged = false;
}
