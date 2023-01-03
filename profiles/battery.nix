{ config, lib, pkgs, ... }:

{
  powerManagement.powertop.enable = true;
  environment.systemPackages = with pkgs; [ powertop ];
}
