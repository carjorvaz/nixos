{ lib, config, ... }:

# From: https://github.com/abread/nixconfig/blob/main/modules/wgrnl.nix

{
  imports = [ ];

  options.networking.wgrnl = {
    enable = lib.mkEnableOption "wgrnl";

    id = lib.mkOption {
      type = lib.types.int;
      description = "Client ID (last octet of IPv4 address)";
    };

    ownPrivateKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to private key";
    };

    peerEndpoint = lib.mkOption {
      type = lib.types.str;
      description = "RNL Wireguard endpoint";
    };

    peerPubkey = lib.mkOption {
      type = lib.types.str;
      description = "RNL Wireguard public key";
    };

    fwmark = lib.mkOption {
      type = lib.types.int;
      default = 765;
      description = "The mark used for policy routing packets directed at the Wireguard tunnel vs the Wireguard peer outside the tunnel";
    };
  };

  config =
    let
      cfg = config.networking.wgrnl;
    in
    lib.mkIf cfg.enable {
      networking.networkmanager.unmanaged = lib.mkIf config.networking.networkmanager.enable [ "wgrnl" ];

      systemd.network = {
        enable = true;

        config.routeTables.wgrnl = cfg.fwmark;

        netdevs."10-wgrnl" = {
          enable = true;
          netdevConfig = {
            Kind = "wireguard";
            MTUBytes = "1300";
            Name = "wgrnl";
          };
          wireguardConfig = {
            PrivateKeyFile = cfg.ownPrivateKeyFile;
            FirewallMark = cfg.fwmark;
            RouteTable = "wgrnl";
          };
          wireguardPeers = [
            {
              wireguardPeerConfig = {
                PublicKey = cfg.peerPubkey;
                Endpoint = cfg.peerEndpoint;
                AllowedIPs = [
                  # public RNL-operated ranges
                  "193.136.164.0/24"
                  "193.136.154.0/24"
                  "2001:690:2100:80::/58"

                  # private RNL-operated ranges
                  "10.16.64.0/18" # DSI-assigned
                  "192.168.154.0/24"
                  "192.168.20.0/24" # wgrnl VPN
                  "fd92:3315:9e43:c490::/64" # wgrnl VPN

                  # multicast
                  "224.0.0.0/24"
                  "ff02::/16"
                  "239.255.255.250/32"
                  "239.255.255.253/32"
                  "fe80::/10"
                ];
                PersistentKeepalive = 25;
              };
            }
          ];
        };
        networks."40-rnl" = {
          name = "wgrnl";

          addresses = [
            { addressConfig.Address = "192.168.20.${builtins.toString cfg.id}/24"; }
            {
              addressConfig.Address = "fd92:3315:9e43:c490::${builtins.toString cfg.id}/64";
              addressConfig.DuplicateAddressDetection = "none";
            }
          ];

          networkConfig = {
            LinkLocalAddressing = "no";
            IPv6AcceptRA = false;
            MulticastDNS = true;
            DNSDefaultRoute = true;
            DNSOverTLS = false;
            DNSSEC = false;
          };

          linkConfig = {
            Multicast = true;
            AllMulticast = false;
          };

          routingPolicyRules = [
            {
              routingPolicyRuleConfig = {
                InvertRule = true;
                FirewallMark = cfg.fwmark;
                Table = "wgrnl";
                Family = "both";
              };
            }
          ];

          ntp = [ "ntp.rnl.tecnico.ulisboa.pt" ];

          dns = [
            "2001:690:2100:80::1"
            "193.136.164.2"
            "2001:690:2100:80::2"
            "193.136.164.1"
          ];

          domains =
            [
              # Main domain, with dns search
              "rnl.tecnico.ulisboa.pt"

              # alt domains
              "~rnl.ist.utl.pt" # spellchecker:disable-line
              "~rnl.pt"

              # public ranges (DSI-assigned)
              "~164.136.193.in-addr.arpa"
              "~154.136.193.in-addr.arpa"
              "~8.0.0.0.0.1.2.0.9.6.0.1.0.0.2.ip6.arpa"

              # private ranges
              "~154.168.192.in-addr.arpa"
              "~20.168.192.in-addr.arpa"
              "~0.9.4.c.3.4.e.9.5.1.3.3.2.9.d.f.ip6.arpa"
            ]
            ++ (
              # private ranges (DSI-assigned)
              builtins.map (octet: "~" + (builtins.toString octet) + ".16.10.in-addr.arpa") (lib.range 64 127)
            );
        };
      };
    };
}
