{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [ gnome-network-displays ];
  networking.firewall.allowedTCPPorts = [ 7236 7250 ];
  networking.firewall.allowedUDPPorts = [ 7236 5353 ];
}
