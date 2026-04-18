{ config, pkgs, ... }:

{
  # Reference:
  # https://github.com/basecamp/omarchy/blob/master/config/hypr/hyprlock.conf
  # https://github.com/basecamp/omarchy/blob/master/themes/gruvbox/hyprlock.conf
  home-manager.users.cjv.programs.hyprlock = {
    enable = true;

    settings = {
      general = {
        # Needed for fingerprint to work with hyprlock.
        # Press enter than tap finger.
        ignore_empty_input = false;
        hide_cursor = true;
      };

      background = [
        {
          monitor = "";
          path = "${config.graphical.theme.wallpaper}";
          blur_passes = 3;
        }
      ];

      input-field = [
        {
          monitor = "";
          size = "650, 100";
          outline_thickness = 4;
          rounding = 0;
          shadow_passes = 0;

          inner_color = "rgba(${config.graphical.theme.palette.bg}cc)";
          outer_color = "rgb(${config.graphical.theme.palette.softFg})";
          font_color = "rgb(${config.graphical.theme.palette.softFg})";
          check_color = "rgb(${config.graphical.theme.palette.warning})";

          fade_on_empty = false;

          placeholder_text = "Enter Password";

          fail_color = "rgb(${config.graphical.theme.palette.critical})";
          fail_text = ''<i>$FAIL ($ATTEMPTS)</i>'';

          position = "0, 0";
          halign = "center";
          valign = "center";
        }
      ];
    };
  };
}
