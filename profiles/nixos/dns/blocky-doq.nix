{
  config,
  lib,
  pkgs,
  ...
}:

let
  hasResolvedSettings = lib.versionAtLeast lib.version "26.05pre";
  localResolvers = [
    "127.0.0.1"
    "::1"
  ];
in
{
  imports = [ ./resolved.nix ];

  networking = {
    nameservers = lib.mkForce localResolvers;

    networkmanager = lib.mkIf config.networking.networkmanager.enable {
      dns = lib.mkDefault "systemd-resolved";
    };
  };

  services = {
    blocky = {
      enable = true;
      enableConfigCheck = true;
      package = lib.mkDefault pkgs.unstable.blocky;
      settings = {
        ports.dns = [
          "127.0.0.1:53"
          "[::1]:53"
        ];

        upstreams = {
          init.strategy = "fast";
          strategy = "parallel_best";
          timeout = "2s";
          quic = {
            maxIdleTimeout = "30s";
            keepAlivePeriod = "15s";
          };
          groups.default = [
            "quic:9.9.9.9:853#dns.quad9.net"
            "quic:149.112.112.112:853#dns.quad9.net"
          ];
        };
      };
    };
  }
  // lib.optionalAttrs hasResolvedSettings {
    resolved.settings.Resolve = {
      DNS = lib.mkForce localResolvers;
      DNSOverTLS = lib.mkForce false;
      DNSSEC = lib.mkForce "allow-downgrade";
      LLMNR = lib.mkForce false;
      Domains = lib.mkForce [ "~." ];
      # systemd-resolved disables compiled-in fallback servers only when the
      # generated file contains an explicit empty FallbackDNS= assignment. An
      # empty list renders as no line, leaving the built-in fallbacks active.
      FallbackDNS = lib.mkForce [ "" ];
    };
  }
  // lib.optionalAttrs (!hasResolvedSettings) {
    resolved = {
      dnsovertls = lib.mkForce "false";
      dnssec = lib.mkForce "allow-downgrade";
      llmnr = lib.mkForce "false";
      domains = lib.mkForce [ "~." ];
      fallbackDns = lib.mkForce [ "" ];
    };
  };
}
