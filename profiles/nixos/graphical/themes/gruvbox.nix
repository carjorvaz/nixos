{ config, lib, ... }:

lib.mkIf (config.graphical.theme.name == "gruvbox") {
  graphical.theme = {
    wallpaper = ./gruvbox.jpg;
    palette = {
      bg = "282828";
      fg = "ebdbb2";
      softFg = "d4be98";
      border = "a89984";
      accent = "d79921";
      info = "458588";
      warning = "d6995c";
      critical = "fb4934";
    };
    appNames = {
      foot = "gruvbox-dark";
      ghostty = "Gruvbox Dark Hard";
      helix = "gruvbox_dark_hard";
      opencode = "gruvbox";
      vscodeDark = "Gruvbox Dark Hard";
      vscodeLight = "Gruvbox Light Hard";
      zellij = "gruvbox-dark";
    };
  };

  # Reference: https://github.com/basecamp/omarchy/tree/master/themes/gruvbox
  programs.foot.theme = "gruvbox-dark";

  home-manager.users.cjv = {
    programs = {
      # Reference https://github.com/basecamp/omarchy/blob/master/themes/gruvbox/btop.theme
      btop = {
        settings.color_theme = "gruvbox";

        themes.gruvbox = ''
          #Bashtop gruvbox (https://github.com/morhetz/gruvbox) theme
          #by BachoSeven

          # Colors should be in 6 or 2 character hexadecimal or single spaced rgb decimal: "#RRGGBB", "#BW" or "0-255 0-255 0-255"
          # example for white: "#FFFFFF", "#ff" or "255 255 255".

          # All graphs and meters can be gradients
          # For single color graphs leave "mid" and "end" variable empty.
          # Use "start" and "end" variables for two color gradient
          # Use "start", "mid" and "end" for three color gradient

          # Main background, empty for terminal default, need to be empty if you want transparent background
          theme[main_bg]="#282828"

          # Main text color
          theme[main_fg]="#a89984"

          # Title color for boxes
          theme[title]="#ebdbb2"

          # Highlight color for keyboard shortcuts
          theme[hi_fg]="#d79921"

          # Background color of selected items
          theme[selected_bg]="#282828"

          # Foreground color of selected items
          theme[selected_fg]="#fabd2f"

          # Color of inactive/disabled text
          theme[inactive_fg]="#282828"

          # Color of text appearing on top of graphs, i.e uptime and current network graph scaling
          theme[graph_text]="#585858"

          # Misc colors for processes box including mini cpu graphs, details memory graph and details status text
          theme[proc_misc]="#98971a"

          # Cpu box outline color
          theme[cpu_box]="#a89984"

          # Memory/disks box outline color
          theme[mem_box]="#a89984"

          # Net up/down box outline color
          theme[net_box]="#a89984"

          # Processes box outline color
          theme[proc_box]="#a89984"

          # Box divider line and small boxes line color
          theme[div_line]="#a89984"

          # Temperature graph colors
          theme[temp_start]="#458588"
          theme[temp_mid]="#d3869b"
          theme[temp_end]="#fb4394"

          # CPU graph colors
          theme[cpu_start]="#b8bb26"
          theme[cpu_mid]="#d79921"
          theme[cpu_end]="#fb4934"

          # Mem/Disk free meter
          theme[free_start]="#4e5900"
          theme[free_mid]=""
          theme[free_end]="#98971a"

          # Mem/Disk cached meter
          theme[cached_start]="#458588"
          theme[cached_mid]=""
          theme[cached_end]="#83a598"

          # Mem/Disk available meter
          theme[available_start]="#d79921"
          theme[available_mid]=""
          theme[available_end]="#fabd2f"

          # Mem/Disk used meter
          theme[used_start]="#cc241d"
          theme[used_mid]=""
          theme[used_end]="#fb4934"

          # Download graph colors
          theme[download_start]="#3d4070"
          theme[download_mid]="#6c71c4"
          theme[download_end]="#a3a8f7"

          # Upload graph colors
          theme[upload_start]="#701c45"
          theme[upload_mid]="#b16286"
          theme[upload_end]="#d3869b"
        '';
      };

      rofi.theme = "gruvbox-dark";

      niri.settings.layout.focus-ring.active.color = "#${config.graphical.theme.palette.border}";

      waybar.style = lib.mkOrder 100 ''
        @define-color bg #${config.graphical.theme.palette.bg};
        @define-color fg #${config.graphical.theme.palette.fg};
        @define-color green_accent #98971a;
        @define-color blue_accent #${config.graphical.theme.palette.info};
        @define-color warning #${config.graphical.theme.palette.accent};
        @define-color critical #${config.graphical.theme.palette.critical};
      '';
    };

    services = {
      mako.settings = {
        background-color = "#${config.graphical.theme.palette.bg}";
        text-color = "#${config.graphical.theme.palette.softFg}";
        border-color = "#${config.graphical.theme.palette.border}";

      };

      wpaperd.settings.default.path = lib.mkDefault config.graphical.theme.wallpaper;
    };

    wayland.windowManager.hyprland.settings.general."col.active_border" =
      "rgb(${config.graphical.theme.palette.border})";
  };
}
