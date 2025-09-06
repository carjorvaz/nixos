{ ... }:

{
  imports = [ ./common.nix ];

  home-manager.users.cjv.programs.waybar.settings.mainBar = {
    modules-left = [ "hyprland/workspaces" ];
    modules-center = [ "hyprland/window" ];

    "hyprland/window" = {
      "max-length" = 200;
      "separate-outputs" = true;
    };

    "hyprland/workspaces" = {
      "on-scroll-up" = "hyprctl dispatch workspace e-1";
      "on-scroll-down" = "hyprctl dispatch workspace e+1";
    };
  };
}
