{ lib, ... }:

{
  options.graphical.theme = {
    name = lib.mkOption {
      type = lib.types.str;
      default = "gruvbox";
      description = "Active graphical theme name.";
    };

    wallpaper = lib.mkOption {
      type = lib.types.path;
      description = "Wallpaper image path for the active theme.";
    };

    palette = lib.mkOption {
      type = lib.types.submodule {
        options = {
          bg = lib.mkOption {
            type = lib.types.str;
            description = "Background color (6-char hex, no #).";
          };

          fg = lib.mkOption {
            type = lib.types.str;
            description = "Foreground color (6-char hex, no #).";
          };

          softFg = lib.mkOption {
            type = lib.types.str;
            description = "Softer foreground/accent text color (6-char hex, no #).";
          };

          border = lib.mkOption {
            type = lib.types.str;
            description = "Border and chrome color (6-char hex, no #).";
          };

          accent = lib.mkOption {
            type = lib.types.str;
            description = "Primary accent color (6-char hex, no #).";
          };

          warning = lib.mkOption {
            type = lib.types.str;
            description = "Warning/check color (6-char hex, no #).";
          };

          critical = lib.mkOption {
            type = lib.types.str;
            description = "Critical/error color (6-char hex, no #).";
          };
        };
      };
      description = "Theme palette consumed by graphical app configs.";
    };

    appNames = lib.mkOption {
      type = lib.types.submodule {
        options = {
          foot = lib.mkOption {
            type = lib.types.str;
            description = "Foot theme name for the active theme.";
          };

          ghostty = lib.mkOption {
            type = lib.types.str;
            description = "Ghostty theme name for the active theme.";
          };

          helix = lib.mkOption {
            type = lib.types.str;
            description = "Helix theme name for the active theme.";
          };

          opencode = lib.mkOption {
            type = lib.types.str;
            description = "Opencode theme name for the active theme.";
          };

          vscodeDark = lib.mkOption {
            type = lib.types.str;
            description = "Preferred dark VS Code theme for the active theme.";
          };

          vscodeLight = lib.mkOption {
            type = lib.types.str;
            description = "Preferred light VS Code theme for the active theme.";
          };

          zellij = lib.mkOption {
            type = lib.types.str;
            description = "Zellij theme name for the active theme.";
          };
        };
      };
      description = "App-specific theme names for the active theme.";
    };
  };
}
