{ ... }:

{
  programs.foot.theme = "gruvbox-dark";

  home-manager.users.cjv = {
    programs.rofi.theme = "gruvbox-dark";

    programs.niri.settings.layout.focus-ring.active.color = "#d79921";

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
