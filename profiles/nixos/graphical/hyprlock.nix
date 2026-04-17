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

          # Omarchy gruvbox colors
          inner_color = "rgba(40, 40, 40, 0.8)";
          outer_color = "rgba(212, 190, 152, 1.0)";
          font_color = "rgba(212, 190, 152, 1.0)";
          check_color = "rgba(214, 153, 92, 1.0)";

          fade_on_empty = false;

          placeholder_text = "Enter Password";

          fail_color = "rgba(251, 73, 52, 1.0)";
          fail_text = ''<i>$FAIL ($ATTEMPTS)</i>'';

          position = "0, 0";
          halign = "center";
          valign = "center";
        }
      ];
    };
  };
}
