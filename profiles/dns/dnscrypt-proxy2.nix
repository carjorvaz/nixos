{ config, lib, pkgs, ... }:

{
  services.resolved = {
    enable = true;
    extraConfig = ''
      DNS=127.0.0.1
      Domains=~.
    '';
  };

  services.dnscrypt-proxy2 = {
    enable = true;
    settings = {
      ipv6_servers = true;
      require_dnssec = true;
      http3 = true;

      sources.public-resolvers = {
        urls = [
          "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
          "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
        ];
        cache_file = "/var/lib/dnscrypt-proxy2/public-resolvers.md";
        minisign_key =
          "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
      };

      # You can choose a specific set of servers from https://github.com/DNSCrypt/dnscrypt-resolvers/blob/master/v3/public-resolvers.md
      server_names = [
        "adguard-dns-unfiltered"
        "adguard-dns-unfiltered-doh"
        "adguard-dns-unfiltered-ipv6"
        "cloudflare"
        "cloudflare-ipv6"
        "controld-uncensored"
        "mullvad-doh"
        "nextdns"
        "nextdns-ipv6"
        "nextdns-ultralow"
        "quad9-dnscrypt-ip4-filter-pri"
        "quad9-doh-ip4-port443-filter-pri"
        "quad9-doh-ip4-port5053-filter-pri"
        "quad9-doh-ip6-port443-filter-pri"
        "quad9-doh-ip6-port5053-filter-pri"
      ];
    };
  };

  systemd.services.dnscrypt-proxy2.serviceConfig = {
    StateDirectory = "dnscrypt-proxy";
  };
}
