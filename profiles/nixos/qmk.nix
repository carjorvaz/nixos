{
  config,
  lib,
  pkgs,
  ...
}:

{
  environment.systemPackages = with pkgs; [ qmk ];
  hardware.keyboard.qmk.enable = true;
}
