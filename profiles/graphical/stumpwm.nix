{ config, lib, pkgs, ... }:

{
  services.xserver.displayManager.startx.enable = true;
}
