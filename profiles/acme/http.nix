{ config, lib, pkgs, ... }:

{
  imports = [ ./common.nix ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
