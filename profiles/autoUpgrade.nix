{ config, lib, pkgs, ... }:

{
  system.autoUpgrade = {
    enable = true;
    flake = "github:carjorvaz/nixos";
    allowReboot = true;
  };
}
