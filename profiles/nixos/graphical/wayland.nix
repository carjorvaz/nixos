{ lib, pkgs, config, ... }:

let
  fontSize = 13;
in
{
  imports = [ ./common.nix ];

  graphical.defaultTerminal = "ghostty";

  # Make electron apps run on Wayland natively.
  environment.sessionVariables = {
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
  };

  environment.systemPackages = with pkgs; [
    waypipe
    wdisplays
    wl-clipboard # wl-copy and wl-paste for copy/paste from stdin / stdout
    wl-mirror # contains wl-present
  ];

  programs.foot = {
    enable = true;

    settings = {
      main = {
        term = "xterm-256color";
        font = lib.mkDefault "monospace:size=${toString fontSize}";

        pad = "14x14";
      };

      mouse.hide-when-typing = "yes";
    };

    theme = lib.mkDefault "gruvbox-dark";
  };

  services.xserver.displayManager.lightdm.enable = false;
  services.displayManager.gdm = {
    enable = lib.mkDefault true;
    wayland = true;
  };

  home-manager.users.cjv = {
    # Solves small cursor on HiDPI.
    home.pointerCursor = {
      name = "breeze_cursors";
      package = pkgs.kdePackages.breeze;
      size = 24;
      gtk.enable = true;
      x11.enable = true;
    };

    gtk = {
      enable = true;
      iconTheme = {
        # name = "Yaru-olive";
        # package = pkgs.yaru-theme;
        # Alternative with better tray icon coverage:
        name = "Papirus-Dark";
        package = pkgs.papirus-icon-theme;
      };
    };

    programs = {
      ghostty = {
        enable = true;
        settings = {
          font-size = fontSize;

          # Reference: https://github.com/basecamp/omarchy/blob/master/config/ghostty/config
          theme = "Gruvbox Dark Hard";
          window-theme = "ghostty";
          window-padding-x = 14;
          window-padding-y = 14;
          confirm-close-surface = false;
          resize-overlay = "never";
          gtk-toolbar-style = "flat";

          cursor-style = "block";
          cursor-style-blink = false;

          shell-integration-features = "no-cursor,ssh-env";

          # Make shift+enter work with Claude Code
          keybind = "shift+enter=text:\\x1b\\r";
        };
      };

      rofi = let term = config.graphical.defaultTerminal; in {
        enable = true;
        cycle = true;
        terminal = "${pkgs.${term}}/bin/${term}";
        plugins = [
          pkgs.rofi-calc
        ];
      };
    };

    services = {
      flameshot.enable = false;
      redshift.enable = false;
      dunst.enable = false;
    };

    xdg.mimeApps = {
      enable = true;
      defaultApplications = {
        # Reference: https://github.com/basecamp/omarchy/blob/master/install/config/mimetypes.sh
        "text/html" = [ "firefox.desktop" ];
        "x-scheme-handler/http" = [ "firefox.desktop" ];
        "x-scheme-handler/https" = [ "firefox.desktop" ];

        "inode/directory" = [ "org.gnome.Nautilus.desktop" ];

        "application/pdf" = [ "org.pwmt.zathura.desktop" ];

        "image/png" = [ "imv.desktop" ];
        "image/jpeg" = [ "imv.desktop" ];
        "image/gif" = [ "imv.desktop" ];
        "image/webp" = [ "imv.desktop" ];
        "image/bmp" = [ "imv.desktop" ];
        "image/tiff" = [ "imv.desktop" ];

        "video/mp4" = [ "mpv.desktop" ];
        "video/x-msvideo" = [ "mpv.desktop" ];
        "video/x-matroska" = [ "mpv.desktop" ];
        "video/x-flv" = [ "mpv.desktop" ];
        "video/x-ms-wmv" = [ "mpv.desktop" ];
        "video/mpeg" = [ "mpv.desktop" ];
        "video/ogg" = [ "mpv.desktop" ];
        "video/webm" = [ "mpv.desktop" ];
        "video/quicktime" = [ "mpv.desktop" ];
        "video/3gpp" = [ "mpv.desktop" ];
        "video/3gpp2" = [ "mpv.desktop" ];
        "video/x-ms-asf" = [ "mpv.desktop" ];
        "video/x-ogm+ogg" = [ "mpv.desktop" ];
        "video/x-theora+ogg" = [ "mpv.desktop" ];
        "application/ogg" = [ "mpv.desktop" ];

        "x-scheme-handler/mailto" = [ "eu.betterbird.Betterbird.desktop" ];

        "text/plain" = [ "nvim.desktop" ];
        "text/english" = [ "nvim.desktop" ];
        "text/x-makefile" = [ "nvim.desktop" ];
        "text/x-c++hdr" = [ "nvim.desktop" ];
        "text/x-c++src" = [ "nvim.desktop" ];
        "text/x-chdr" = [ "nvim.desktop" ];
        "text/x-csrc" = [ "nvim.desktop" ];
        "text/x-java" = [ "nvim.desktop" ];
        "text/x-moc" = [ "nvim.desktop" ];
        "text/x-pascal" = [ "nvim.desktop" ];
        "text/x-tcl" = [ "nvim.desktop" ];
        "text/x-tex" = [ "nvim.desktop" ];
        "application/x-shellscript" = [ "nvim.desktop" ];
        "text/x-c" = [ "nvim.desktop" ];
        "text/x-c++" = [ "nvim.desktop" ];
        "application/xml" = [ "nvim.desktop" ];
        "text/xml" = [ "nvim.desktop" ];
      };
    };
  };
}
