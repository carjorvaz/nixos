{ config, lib, pkgs, ... }:

{
  programs.wireshark.enable = true;
  users.users.cjv.extraGroups = [ "wireshark" ];
}
