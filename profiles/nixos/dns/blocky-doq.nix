{
  config,
  lib,
  pkgs,
  ...
}:

let
  hasResolvedSettings = lib.versionAtLeast lib.version "26.05pre";
  tailnetDomain = "tail01b8d.ts.net";
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

  # Start blocky only after the link is online; otherwise its first upstream
  # probes can run before routes exist and log "network is unreachable".
  systemd.services.blocky.after = [ "network-online.target" ];

  services = {
    # Tailscale's accept-dns was installing tailscale0 as the default-route
    # resolver with the tailnet's AdGuard upstreams, so resolved sent every
    # query to MagicDNS and blocky was bypassed. Make blocky authoritative and
    # forward only ts.net back to MagicDNS, so tailnet names still resolve.
    tailscale.extraSetFlags = lib.mkIf config.services.tailscale.enable [ "--accept-dns=false" ];

    blocky = {
      enable = true;
      enableConfigCheck = true;
      package = lib.mkDefault pkgs.unstable.blocky;
      settings = {
        ports.dns = [
          "127.0.0.1:53"
          "[::1]:53"
        ];

        # Per-query INFO logging filled pius's 50M journal (123k lines/day) and
        # hadrianus's with data nothing consumes. The journal now keeps service
        # logs instead.
        queryLog.type = "none";

        # The default cache is unbounded (maxItemsCount=0). Bound it on the
        # 2 GB host; entries are small and TTLs still come from the response.
        caching.maxItemsCount = 10000;

        # MagicDNS stays reachable at 100.100.100.100 even with accept-dns
        # off; only the tailnet suffix is forwarded there.
        conditional.mapping."ts.net" = "100.100.100.100";

        upstreams = {
          init.strategy = "fast";
          # Strict order: normal queries go to Quad9 over QUIC only. The other
          # Quad9 address, a DoT fallback for networks that block UDP/853, and
          # a last-resort Cloudflare entry are tried only if the previous
          # upstream fails. Previously parallel_best picked two of five
          # resolvers per query, leaking every query to Cloudflare/AdGuard.
          strategy = "strict";
          timeout = "2s";
          quic = {
            maxIdleTimeout = "30s";
            keepAlivePeriod = "15s";
          };
          groups.default = [
            "quic:9.9.9.9:853#dns.quad9.net"
            "quic:149.112.112.112:853#dns.quad9.net"
            "tcp-tls:9.9.9.9:853#dns.quad9.net"
            "quic:1.1.1.1:853#cloudflare-dns.com"
          ];
        };
      };
    };
  }
  // lib.optionalAttrs hasResolvedSettings {
    resolved.settings.Resolve = {
      DNS = lib.mkForce localResolvers;
      DNSOverTLS = lib.mkForce false;
      # Quad9 validates DNSSEC upstream; blocky forwards unsigned replies and
      # resolved's allow-downgrade still rejects them as "no-signature".
      # Disable the duplicate local validator (Quad9's forwarder guidance).
      DNSSEC = lib.mkForce "false";
      LLMNR = lib.mkForce false;
      # ~. makes blocky the resolver for everything; the second entry keeps
      # single-label tailnet names working now that Tailscale no longer writes
      # its own search domain.
      Domains = lib.mkForce [
        "~."
        tailnetDomain
      ];
      # systemd-resolved disables compiled-in fallback servers only when the
      # generated file contains an explicit empty FallbackDNS= assignment. An
      # empty list renders as no line, leaving the built-in fallbacks active.
      FallbackDNS = lib.mkForce [ "" ];
    };
  }
  // lib.optionalAttrs (!hasResolvedSettings) {
    resolved = {
      dnsovertls = lib.mkForce "false";
      dnssec = lib.mkForce "false";
      llmnr = lib.mkForce "false";
      domains = lib.mkForce [
        "~."
        tailnetDomain
      ];
      fallbackDns = lib.mkForce [ "" ];
    };
  };
}
