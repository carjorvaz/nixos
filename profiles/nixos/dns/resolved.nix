{ config, lib, pkgs, ... }:

{
  networking.nameservers = lib.mkDefault [ "9.9.9.9#dns.quad9.net" ];
  services.resolved = {
    enable = true;
    domains = [ "~." ];
    extraConfig = ''
      DNSOverTLS=yes
    '';
  };
}
