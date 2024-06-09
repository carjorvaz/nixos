{
  config,
  lib,
  pkgs,
  ...
}:

{
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
}
