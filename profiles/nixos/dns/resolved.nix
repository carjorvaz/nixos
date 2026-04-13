{ lib, ... }:

let
  hasResolvedSettings = lib.versionAtLeast lib.version "26.05pre";
in
({
    networking.nameservers = lib.mkDefault [ "9.9.9.9#dns.quad9.net" ];

    # Don't restart resolved during nixos-rebuild switch to avoid DNS gaps.
    systemd.services.systemd-resolved.stopIfChanged = false;
  }
  // lib.optionalAttrs hasResolvedSettings {
    services.resolved = {
      enable = true;
      settings.Resolve = {
        DNSOverTLS = "opportunistic";
        DNSSEC = "allow-downgrade";
        LLMNR = false;
        Domains = [ "~." ];
      };
    };
  }
  // lib.optionalAttrs (!hasResolvedSettings) {
    services.resolved = {
      enable = true;
      dnsovertls = "opportunistic";
      dnssec = "allow-downgrade";
      llmnr = "false";
      domains = [ "~." ];
    };
  })
