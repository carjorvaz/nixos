{
  config,
  lib,
  pkgs,
  ...
}:
with lib;

let
  cfgFile = pkgs.formats.yaml { }.generate "blocky.yml" {
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
        "quic:1.1.1.1:853#cloudflare-dns.com"
        "quic:1.0.0.1:853#cloudflare-dns.com"
        "quic:dns.adguard-dns.com:853"
      ];
    };
  };

  plist = pkgs.writeText "io.oxerr.blocky.plist" ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>io.oxerr.blocky</string>
      <key>ProgramArguments</key>
      <array>
        <string>${pkgs.blocky}/bin/blocky</string>
        <string>--config</string>
        <string>${cfgFile}</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>ProcessType</key>
      <string>Background</string>
      <key>StandardOutPath</key>
      <string>/var/log/blocky.log</string>
      <key>StandardErrorPath</key>
      <string>/var/log/blocky.err</string>
    </dict>
    </plist>
  '';
in
{
  networking = {
    knownNetworkServices = [ "Wi-Fi" ];
    dns = mkForce [
      "127.0.0.1"
      "::1"
    ];
  };

  environment = {
    systemPackages = [ pkgs.blocky ];
    launchDaemons.blocky.source = plist;
  };
}
