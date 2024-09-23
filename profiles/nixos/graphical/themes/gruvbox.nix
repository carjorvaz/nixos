{ ... }:

{
  home-manager.users.cjv = {
    programs = {
      foot = {
        settings = {
          colors = {
            background = "282828";
            foreground = "ebdbb2";

            regular0 = "282828";
            regular1 = "cc241d";
            regular2 = "98971a";
            regular3 = "d79921";
            regular4 = "458588";
            regular5 = "b16286";
            regular6 = "689d6a";
            regular7 = "a89984";

            bright0 = "928374";
            bright1 = "fb4934";
            bright2 = "b8bb26";
            bright3 = "fabd2f";
            bright4 = "83a598";
            bright5 = "d3869b";
            bright6 = "8ec07c";
            bright7 = "ebdbb2";
          };
        };
      };

      rofi.theme = "gruvbox-dark";
    };

    services.mako = {
      backgroundColor = "#282828";
      textColor = "#ebdbb2";
      progressColor = "#ebdbb2";
      borderColor = "#928374";
      extraConfig = ''
        border-size=3
        border-radius=6
      '';
    };

    wayland.windowManager = {
      hyprland.settings = {
        general = {
          no_border_on_floating = false;
          "col.active_border" = "rgb(d79921)";
          "col.inactive_border" = "rgb(282828)";
        };

        plugin.hy3.tabs = {
          "col.active" = "rgb(d79921)";
          "col.inactive" = "rgb(282828)";
          "col.urgent" = "rgb(cc241d)";

          "col.text.active" = "rgb(282828)";
          "col.text.urgent" = "rgb(ebdbb2)";
          "col.text.inactive" = "rgb(ebdbb2)";
        };
      };

      sway.config.colors = {
        background = "#282828";

        # https://github.com/a-schaefers/i3-wm-gruvbox-theme/blob/master/i3/config
        # blue gruvbox
        focused = {
          border = "#458588";
          background = "#458588";
          text = "#1d2021";
          indicator = "#b16286";
          childBorder = "#1d2021";
        };

        focusedInactive = {
          border = "#1d2021 ";
          background = "#1d2021 ";
          text = "#d79921 ";
          indicator = "#b16286 ";
          childBorder = "#1d2021";
        };

        unfocused = {
          border = "#1d2021 ";
          background = "#1d2021 ";
          text = "#d79921 ";
          indicator = "#b16286 ";
          childBorder = "#1d2021";
        };

        urgent = {
          border = "#cc241d ";
          background = "#cc241d ";
          text = "#ebdbb2 ";
          indicator = "#cc241d ";
          childBorder = "#cc241d";
        };
      };
    };
  };
}
