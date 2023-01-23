{ config, lib, pkgs, ... }:

{
  services.resolved = {
    enable = true;
    extraConfig = ''
      DNS=1.1.1.1#one.one.one.one
      DNSOverTLS=yes
      Domains=~.
    '';
  };
}
