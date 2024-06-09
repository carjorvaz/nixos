{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Set third key right of spacebar to AltGr on physical japanese keyboards
  services.xserver.displayManager.sessionCommands =
    let
      myLayout = pkgs.writeText "xkb-layout" ''
        keycode 135 = ISO_Level3_Shift
      '';
    in
    "${pkgs.xorg.xmodmap}/bin/xmodmap ${myLayout}";
}
