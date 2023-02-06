{ config, lib, pkgs, ... }:

{
  networking.nameservers = lib.mkDefault [ "1.1.1.1#one.one.one.one" ];
  services.resolved = {
    enable = true;
    domains = [ "~." ];
    extraConfig = ''
      DNSOverTLS=yes
    '';
  };
}
