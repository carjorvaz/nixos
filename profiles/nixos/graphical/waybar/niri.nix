{ ... }:

{
  imports = [ ./common.nix ];

  home-manager.users.cjv.programs.waybar.settings.mainBar = {
    modules-left = [ ];
    modules-center = [ ];
  };
}
