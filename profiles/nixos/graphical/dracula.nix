{ config, lib, pkgs, ... }:

{
  environment.sessionVariables.FZF_DEFAULT_OPTS =
    "--color=fg:#f8f8f2,bg:#282a36,hl:#bd93f9 --color=fg+:#f8f8f2,bg+:#44475a,hl+:#bd93f9 --color=info:#ffb86c,prompt:#50fa7b,pointer:#ff79c6 --color=marker:#ff79c6,spinner:#ffb86c,header:#6272a4";

  home-manager.users.cjv = {
    programs = {
      dircolors.settings = {
        COLORTERM = "?*";
        RESET = ''0  # reset to " normal " color'';
        DIR = "01;38;2;189;147;249 # directory";
        LINK =
          "01;38;2;139;233;253 # symbolic link.  (If you set this to 'target' instead of a";
        MULTIHARDLINK = "00 # regular file with more than one link";
        FIFO = "48;2;33;34;44;38;2;241;250;140 # pipe";
        SOCK = "01;38;2;255;121;198 # socket";
        DOOR = "01;38;2;255;121;198 # door";
        BLK = "48;2;33;34;44;38;2;241;250;140;01 # block device driver";
        CHR = "48;2;33;34;44;38;2;241;250;140;01 # character device driver";
        ORPHAN =
          "48;2;33;34;44;38;2;255;85;85;01 # symlink to nonexistent file, or non-stat'able file ...";
        MISSING = "00      # ... and the files they point to";
        SETUID = "38;2;248;248;242;48;2;255;85;85 # file that is setuid (u+s)";
        SETGID = "38;2;33;34;44;48;2;241;250;140 # file that is setgid (g+s)";
        CAPABILITY = "00 # file with capability (very expensive to lookup)";
        STICKY_OTHER_WRITABLE =
          "38;2;33;34;44;48;2;80;250;123 # dir that is sticky and other-writable (+t,o+w)";
        OTHER_WRITABLE =
          "38;2;189;147;249;48;2;80;250;123 # dir that is other-writable (o+w) and not sticky";
        STICKY =
          "38;2;248;248;242;48;2;189;147;249 # dir with the sticky bit set (+t) and not other-writable";
        EXEC = "01;38;2;80;250;123";
        ".tar" = "01;38;2;255;85;85";
        ".tgz" = "01;38;2;255;85;85";
        ".arc" = "01;38;2;255;85;85";
        ".arj" = "01;38;2;255;85;85";
        ".taz" = "01;38;2;255;85;85";
        ".lha" = "01;38;2;255;85;85";
        ".lz4" = "01;38;2;255;85;85";
        ".lzh" = "01;38;2;255;85;85";
        ".lzma" = "01;38;2;255;85;85";
        ".tlz" = "01;38;2;255;85;85";
        ".txz" = "01;38;2;255;85;85";
        ".tzo" = "01;38;2;255;85;85";
        ".t7z" = "01;38;2;255;85;85";
        ".zip" = "01;38;2;255;85;85";
        ".z" = "  01;38;2;255;85;85";
        ".dz" = " 01;38;2;255;85;85";
        ".gz" = " 01;38;2;255;85;85";
        ".lrz" = "01;38;2;255;85;85";
        ".lz" = " 01;38;2;255;85;85";
        ".lzo" = "01;38;2;255;85;85";
        ".xz" = " 01;38;2;255;85;85";
        ".zst" = "01;38;2;255;85;85";
        ".tzst" = "01;38;2;255;85;85";
        ".bz2" = "01;38;2;255;85;85";
        ".bz" = " 01;38;2;255;85;85";
        ".tbz" = "01;38;2;255;85;85";
        ".tbz2" = "01;38;2;255;85;85";
        ".tz" = " 01;38;2;255;85;85";
        ".deb" = "01;38;2;255;85;85";
        ".rpm" = "01;38;2;255;85;85";
        ".jar" = "01;38;2;255;85;85";
        ".war" = "01;38;2;255;85;85";
        ".ear" = "01;38;2;255;85;85";
        ".sar" = "01;38;2;255;85;85";
        ".rar" = "01;38;2;255;85;85";
        ".alz" = "01;38;2;255;85;85";
        ".ace" = "01;38;2;255;85;85";
        ".zoo" = "01;38;2;255;85;85";
        ".cpio" = "01;38;2;255;85;85";
        ".7z" = " 01;38;2;255;85;85";
        ".rz" = " 01;38;2;255;85;85";
        ".cab" = "01;38;2;255;85;85";
        ".wim" = "01;38;2;255;85;85";
        ".swm" = "01;38;2;255;85;85";
        ".dwm" = "01;38;2;255;85;85";
        ".esd" = "01;38;2;255;85;85";
        ".avif" = "01;38;2;255;121;198";
        ".jpg" = "01;38;2;255;121;198";
        ".jpeg" = "01;38;2;255;121;198";
        ".mjpg" = "01;38;2;255;121;198";
        ".mjpeg" = "01;38;2;255;121;198";
        ".gif" = "01;38;2;255;121;198";
        ".bmp" = "01;38;2;255;121;198";
        ".pbm" = "01;38;2;255;121;198";
        ".pgm" = "01;38;2;255;121;198";
        ".ppm" = "01;38;2;255;121;198";
        ".tga" = "01;38;2;255;121;198";
        ".xbm" = "01;38;2;255;121;198";
        ".xpm" = "01;38;2;255;121;198";
        ".tif" = "01;38;2;255;121;198";
        ".tiff" = "01;38;2;255;121;198";
        ".png" = "01;38;2;255;121;198";
        ".svg" = "01;38;2;255;121;198";
        ".svgz" = "01;38;2;255;121;198";
        ".mng" = "01;38;2;255;121;198";
        ".pcx" = "01;38;2;255;121;198";
        ".mov" = "01;38;2;255;121;198";
        ".mpg" = "01;38;2;255;121;198";
        ".mpeg" = "01;38;2;255;121;198";
        ".m2v" = "01;38;2;255;121;198";
        ".mkv" = "01;38;2;255;121;198";
        ".webm" = "01;38;2;255;121;198";
        ".webp" = "01;38;2;255;121;198";
        ".ogm" = "01;38;2;255;121;198";
        ".mp4" = "01;38;2;255;121;198";
        ".m4v" = "01;38;2;255;121;198";
        ".mp4v" = "01;38;2;255;121;198";
        ".vob" = "01;38;2;255;121;198";
        ".qt" = " 01;38;2;255;121;198";
        ".nuv" = "01;38;2;255;121;198";
        ".wmv" = "01;38;2;255;121;198";
        ".asf" = "01;38;2;255;121;198";
        ".rm" = " 01;38;2;255;121;198";
        ".rmvb" = "01;38;2;255;121;198";
        ".flc" = "01;38;2;255;121;198";
        ".avi" = "01;38;2;255;121;198";
        ".fli" = "01;38;2;255;121;198";
        ".flv" = "01;38;2;255;121;198";
        ".gl" = "01;38;2;255;121;198";
        ".dl" = "01;38;2;255;121;198";
        ".xcf" = "01;38;2;255;121;198";
        ".xwd" = "01;38;2;255;121;198";
        ".yuv" = "01;38;2;255;121;198";
        ".cgm" = "01;38;2;255;121;198";
        ".emf" = "01;38;2;255;121;198";
        ".ogv" = "01;38;2;255;121;198";
        ".ogx" = "01;38;2;255;121;198";
        ".aac" = "00;38;2;139;233;253";
        ".au" = "00;38;2;139;233;253";
        ".flac" = "00;38;2;139;233;253";
        ".m4a" = "00;38;2;139;233;253";
        ".mid" = "00;38;2;139;233;253";
        ".midi" = "00;38;2;139;233;253";
        ".mka" = "00;38;2;139;233;253";
        ".mp3" = "00;38;2;139;233;253";
        ".mpc" = "00;38;2;139;233;253";
        ".ogg" = "00;38;2;139;233;253";
        ".ra" = "00;38;2;139;233;253";
        ".wav" = "00;38;2;139;233;253";
        ".oga" = "00;38;2;139;233;253";
        ".opus" = "00;38;2;139;233;253";
        ".spx" = "00;38;2;139;233;253";
        ".xspf" = "00;38;2;139;233;253";
        "*~" = "00;38;2;98;114;164";
        "*#" = "00;38;2;98;114;164";
        ".bak" = "00;38;2;98;114;164";
        ".crdownload" = "00;38;2;98;114;164";
        ".dpkg-dist" = "00;38;2;98;114;164";
        ".dpkg-new" = "00;38;2;98;114;164";
        ".dpkg-old" = "00;38;2;98;114;164";
        ".dpkg-tmp" = "00;38;2;98;114;164";
        ".old" = "00;38;2;98;114;164";
        ".orig" = "00;38;2;98;114;164";
        ".part" = "00;38;2;98;114;164";
        ".rej" = "00;38;2;98;114;164";
        ".rpmnew" = "00;38;2;98;114;164";
        ".rpmorig" = "00;38;2;98;114;164";
        ".rpmsave" = "00;38;2;98;114;164";
        ".swp" = "00;38;2;98;114;164";
        ".tmp" = "00;38;2;98;114;164";
        ".ucf-dist" = "00;38;2;98;114;164";
        ".ucf-new" = "00;38;2;98;114;164";
        ".ucf-old" = "00;38;2;98;114;164";
      };

      foot.settings.colors = {
        background = "282a36";
        foreground = "f8f8f2";

        ## Normal/regular colors (color palette 0-7)
        regular0 = "21222c"; # black
        regular1 = "ff5555"; # red
        regular2 = "50fa7b"; # green
        regular3 = "f1fa8c"; # yellow
        regular4 = "bd93f9"; # blue
        regular5 = "ff79c6"; # magenta
        regular6 = "8be9fd"; # cyan
        regular7 = "f8f8f2"; # white

        ## Bright colors (color palette 8-15)
        bright0 = "6272a4"; # bright black
        bright1 = "ff6e6e"; # bright red
        bright2 = "69ff94"; # bright green
        bright3 = "ffffa5"; # bright yellow
        bright4 = "d6acff"; # bright blue
        bright5 = "ff92df"; # bright magenta
        bright6 = "a4ffff"; # bright cyan
        bright7 = "ffffff"; # bright white

        selection-foreground = "ffffff";
        selection-background = "44475a";
        urls = "8be9fd";
      };

      # TODO file in-line here instead of separate file
      rofi.theme = ./dracula.rasi;

      swaylock = {
        settings = {
          # image=~/.config/swaylock/dracula-wallpaper.svg
          color = "282a36";
          inside-color = "1F202A";
          line-color = "1F202A";
          ring-color = "bd93f9";
          text-color = "f8f8f2";

          layout-bg-color = "1F202A";
          layout-text-color = "f8f8f2";

          inside-clear-color = "6272a4";
          line-clear-color = "1F202A";
          ring-clear-color = "6272a4";
          text-clear-color = "1F202A";

          inside-ver-color = "bd93f9";
          line-ver-color = "1F202A";
          ring-ver-color = "bd93f9";
          text-ver-color = "1F202A";

          inside-wrong-color = "ff5555";
          line-wrong-color = "1F202A";
          ring-wrong-color = "ff5555";
          text-wrong-color = "1F202A";

          bs-hl-color = "ff5555";
          key-hl-color = "50fa7b";

          text-caps-lock-color = "f8f8f2";
        };
      };
    };

    services.mako = {
      backgroundColor = "#282a36";
      textColor = "#44475a";
      borderColor = "#282a36";
      extraConfig = ''
        [urgency=low]
        border-color=#282a36

        [urgency=normal]
        border-color=#f1fa8c

        [urgency=high]
        border-color=#ff5555
      '';
    };

    wayland.windowManager = {
      hyprland = {
        settings = {
          decoration = {
            "col.shadow" = "rgba(1E202966)";

            # suggested shadow setting
            drop_shadow = "yes";
            shadow_range = 60;
            shadow_offset = "1 2";
            shadow_render_power = 3;
            shadow_scale = "0.97";
          };

          general = {
            no_border_on_floating = false;

            # "col.active_border" = "rgb(44475a) rgb(bd93f9) 90deg";
            # "col.inactive_border" = "rgba(44475aaa)";
            # "col.nogroup_border" = "rgba(282a36dd)";
            # "col.nogroup_border_active" = "rgb(bd93f9) rgb(44475a) 90deg";

            # # non-gradient alternative
            # "col.active_border" = "rgb(bd93f9)";
            # "col.inactive_border" = "rgba(44475aaa)";
            # "col.nogroup_border" = "rgba(282a36dd)";
            # "col.nogroup_border_active" = "rgb(bd93f9)";

            # darker alternative
            "col.active_border" = "rgb(44475a)"; # or rgb(6272a4)
            "col.inactive_border" = "rgb(282a36)";
            "col.nogroup_border" = "rgb(282a36)";
            "col.nogroup_border_active" = "rgb(44475a)"; # or rgb(6272a4)
          };

          group = {
            groupbar = {
              "col.active" = "rgb(bd93f9) rgb(44475a) 90deg";
              "col.inactive" = "rgba(282a36dd)";
            };
          };

          windowrulev2 = [
            "nomaximizerequest, class:.*" # You'll probably like this.
            "bordercolor rgb(ff5555),xwayland:1" # check if window is xwayland
          ];
        };
      };

      sway = {
        config = rec {
          colors = {
            background = "#F8F8F2";
            focused = "#6272A4 #6272A4 #F8F8F2 #6272A4 #6272A4";
            focusedInactive = "#44475A #44475A #F8F8F2 #44475A #44475A";
            placeholder = "#282A36 #282A36 #F8F8F2 #282A36 #282A36";
            unfocused = "#282A36 #282A36 #BFBFBF #282A36 #282A36";
            urgent = "#44475A #FF5555 #F8F8F2 #FF5555 #FF5555";
          };
        };
      };
    };
  };
}
