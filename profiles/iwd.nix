{ config, lib, pkgs, ... }:

{
  networking.wireless.iwd.enable = true;
  networking.networkmanager.wifi.backend = "iwd";
}
