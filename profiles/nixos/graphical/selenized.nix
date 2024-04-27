{ config, lib, pkgs, ... }:

{
  home-manager.users.cjv = {
    programs = {
      # https://github.com/jan-warchol/selenized/tree/master/other-apps/dircolors
      dircolors.settings.ow = "1;7;34:st=30;44:su=30;41";

      foot = {
        settings = {
          cursor.color = "181818 56d8c9";
          colors = {
            background = "181818";
            foreground = "b9b9b9";

            regular0 = "252525";
            regular1 = "ed4a46";
            regular2 = "70b433";
            regular3 = "dbb32d";
            regular4 = "368aeb";
            regular5 = "eb6eb7";
            regular6 = "3fc5b7";
            regular7 = "777777";

            bright0 = "3b3b3b";
            bright1 = "ff5e56";
            bright2 = "83c746";
            bright3 = "efc541";
            bright4 = "4f9cfe";
            bright5 = "ff81ca";
            bright6 = "56d8c9";
            bright7 = "dedede";
          };
        };
      };

      rofi.theme = ./selenized.rasi;

      swaylock = {
        settings = {
          color = "181818";
          inside-color = "181818";
          line-color = "181818";
          ring-color = "777777";
          text-color = "b9b9b9";

          layout-bg-color = "181818";
          layout-text-color = "b9b9b9";

          inside-clear-color = "efc541";
          line-clear-color = "181818";
          ring-clear-color = "dbb32d";
          text-clear-color = "181818";

          inside-ver-color = "4f9cfe";
          line-ver-color = "181818";
          ring-ver-color = "368aeb";
          text-ver-color = "181818";

          inside-wrong-color = "ff5e56";
          line-wrong-color = "181818";
          ring-wrong-color = "ed4a46";
          text-wrong-color = "181818";

          bs-hl-color = "ed4a46";
          key-hl-color = "70b433";

          text-caps-lock-color = "b9b9b9";
        };
      };
    };

    services.mako = {
      backgroundColor = "#181818";
      textColor = "#b9b9b9";
      borderColor = "#181818";
      extraConfig = ''
        [urgency=low]
        border-color=#181818

        [urgency=normal]
        border-color=#dbb32d

        [urgency=high]
        border-color=#ed4a46
      '';
    };

    wayland.windowManager = {
      hyprland = {
        settings = {
          decoration = {
            "col.shadow" = "rgba(18181866)";

            # suggested shadow setting
            shadow_range = 60;
            shadow_offset = "1 2";
            shadow_render_power = 3;
            shadow_scale = "0.97";
          };

          general = {
            no_border_on_floating = false;
            "col.active_border" = "rgb(dbb32d)";
            "col.inactive_border" = "rgb(181818)";
            "col.nogroup_border" = "rgb(181818)";
            "col.nogroup_border_active" = "rgb(3b3b3b)";
          };

          group = {
            groupbar = {
              "col.active" = "rgb(777777) rgb(3b3b3b) 90deg";
              "col.inactive" = "rgba(181818dd)";
            };
          };

          windowrulev2 = [
            "nomaximizerequest, class:.*" # You'll probably like this.
            "bordercolor rgb(ed4a46),xwayland:1" # check if window is xwayland
          ];
        };
      };
    };
  };
}
