{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  wallpaper = ./wallpaper.jpg;
in
{
  imports = [
    ./themes/gruvbox.nix
    ./wayland.nix
    ./hyprshade.nix
  ];

  programs = {
    hyprland = {
      enable = true;
      package = pkgs.unstable.hyprland;
    };

    hyprlock.enable = true;
  };

  services.hypridle.enable = true;

  home-manager.users.cjv = {
    wayland.windowManager.hyprland = {
      enable = true;
      xwayland.enable = true;

      # Whether to enable hyprland-session.target on hyprland startup
      systemd = {
        enable = true;
        variables = [ "--all" ];
      };

      settings = {
        # See https://wiki.hyprland.org/Configuring/Keywords/ for more

        # Execute your favorite apps at launch
        exec-once = [ ];

        "$terminal" = "foot";
        "$menu" = "rofi";

        env = [
          "XCURSOR_SIZE,24"
          "QT_QPA_PLATFORMTHEME,qt5ct" # change to qt6ct if you have that
        ];

        # https://wiki.hyprland.org/Configuring/Variables/
        input = {
          kb_layout = "us";
          kb_variant = "altgr-intl";
          kb_options = "ctrl:nocaps";

          repeat_delay = 200;
          repeat_rate = 25;

          accel_profile = "flat";
          follow_mouse = 1;

          touchpad = {
            natural_scroll = true;
            scroll_factor = "0.2";
          };

          sensitivity = lib.mkDefault 0; # -1.0 - 1.0, 0 means no modification.
        };

        general = {
          gaps_in = lib.mkDefault 5;
          gaps_out = lib.mkDefault 10;
          border_size = lib.mkDefault 2;

          "col.active_border" = lib.mkDefault "rgba(33ccffee) rgba(00ff99ee) 45deg";
          "col.inactive_border" = lib.mkDefault "rgba(595959aa)";

          layout = "hy3";
        };

        decoration = {
          rounding = lib.mkDefault 10;

          # https://wiki.hyprland.org/FAQ/#how-do-i-make-hyprland-draw-as-little-power-as-possible-on-my-laptop
          blur.enabled = false;
          drop_shadow = false;
        };

        # https://wiki.hyprland.org/FAQ/#how-heavy-is-this
        # I prefer no animations so it feels snappier.
        animations.enabled = false;

        # https://wiki.hyprland.org/Configuring/Dwindle-Layout/
        dwindle = {
          force_split = 2; # spawn new windows on the right/bottom
        };

        misc = {
          vfr = true;

          # Set to 0 to disable the anime mascot wallpapers
          force_default_wallpaper = 0;
          disable_hyprland_logo = false;
        };

        monitor = [ ",preferred,auto,auto" ];

        # Example windowrule v1
        # windowrule = float, ^(kitty)$
        # Example windowrule v2
        # windowrulev2 = float,class:^(kitty)$,title:^(kitty)$
        # See https://wiki.hyprland.org/Configuring/Window-Rules/ for more

        # Check class with: hyprctl clients | grep class
        windowrulev2 = [
          "workspace 2 silent, class:^(emacs)$"
          "workspace 7 silent, class:^(betterbird)$"
          "workspace 8 silent, class:^(signal)$"
          "workspace 9 silent, class:^(discord)$"
        ];

        workspace = [ ];

        # See https://wiki.hyprland.org/Configuring/Keywords/ for more
        "$mainMod" = "SUPER";

        # Example binds, see https://wiki.hyprland.org/Configuring/Binds/ for more
        bind = [
          "$mainMod, ESCAPE, exec, hyprlock"
          "$mainMod, RETURN, exec, $terminal"
          "$mainMod SHIFT, Q, hy3:killactive,"
          "$mainMod SHIFT, E, exit,"
          "$mainMod SHIFT, space, togglefloating,"

          # Brightness - logarithmic scale
          ", XF86MonBrightnessDown, exec, ${pkgs.light}/bin/light -T 0.618"
          ", XF86MonBrightnessUp, exec, ${pkgs.light}/bin/light -T 1.618"

          # Audio - logarithmic scale
          ", XF86AudioLowerVolume, exec, ${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -2dB"
          ", XF86AudioRaiseVolume, exec, ${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +2dB"
          ", XF86AudioMute, exec, ${pkgs.pamixer}/bin/pamixer -t"
          ", XF86AudioMicMute, exec, ${pkgs.pamixer}/bin/pamixer --default-source -t"

          # Rofi
          "$mainMod, D, exec, $menu -modes combi -show combi"
          "$mainMod SHIFT, D, exec, $menu -modes drun -show drun"
          "$mainMod, C, exec, $menu -modes calc -show calc"

          # Screenshots; copied from: https://github.com/amadejkastelic/nixos-config/blob/0663337fddd2a5048eafb6231d2f378aee5d2bac/home/programs/wayland/hyprland/binds.nix#L2
          ''$mainMod, P, exec, shader=$(hyprshade current) && hyprshade off && ${pkgs.grimblast}/bin/grimblast --freeze --notify copy area; hyprshade on "$shader"''
          ''$mainMod SHIFT, P, exec, shader=$(hyprshade current) && hyprshade off && ${pkgs.grimblast}/bin/grimblast --freeze --notify copysave area /tmp/$(${pkgs.coreutils}/bin/date +'%H:%M:%S.png'); hyprshade on "$shader"''

          # Move focus with mainMod + arrow keys
          "$mainMod, left, hy3:movefocus, l"
          "$mainMod, right, hy3:movefocus, r"
          "$mainMod, up, hy3:movefocus, u"
          "$mainMod, down, hy3:movefocus, d"

          # Move window with mainMod + arrow keys
          "$mainMod SHIFT, left, hy3:movewindow, l"
          "$mainMod SHIFT, right, hy3:movewindow, r"
          "$mainMod SHIFT, up, hy3:movewindow, u"
          "$mainMod SHIFT, down, hy3:movewindow, d"

          # Move focus with mainMod + vim keys
          "$mainMod, h, hy3:movefocus, l"
          "$mainMod, j, hy3:movefocus, d"
          "$mainMod, k, hy3:movefocus, u"
          "$mainMod, l, hy3:movefocus, r"

          # Move window with mainMod + vim keys
          "$mainMod SHIFT, h, hy3:movewindow, l"
          "$mainMod SHIFT, j, hy3:movewindow, d"
          "$mainMod SHIFT, k, hy3:movewindow, u"
          "$mainMod SHIFT, l, hy3:movewindow, r"

          "$mainMod, v, hy3:makegroup, h"
          "$mainMod, b, hy3:makegroup, v"

          "$mainMod, w, hy3:makegroup, tab"

          "$mainMod, a, hy3:changefocus, raise"
          "$mainMod SHIFT, a, hy3:changefocus, lower"

          "$mainMod, e, hy3:changegroup, opposite"

          # Move focus between monitors
          "$mainMod, comma, focusmonitor, l"
          "$mainMod, period, focusmonitor, r"

          # Move workspace between monitors
          "$mainMod SHIFT, comma, movecurrentworkspacetomonitor, l"
          "$mainMod SHIFT, period, movecurrentworkspacetomonitor, r"

          # Switch workspaces with mainMod + [0-9]
          "$mainMod, 1, workspace, 1"
          "$mainMod, 2, workspace, 2"
          "$mainMod, 3, workspace, 3"
          "$mainMod, 4, workspace, 4"
          "$mainMod, 5, workspace, 5"
          "$mainMod, 6, workspace, 6"
          "$mainMod, 7, workspace, 7"
          "$mainMod, 8, workspace, 8"
          "$mainMod, 9, workspace, 9"
          "$mainMod, 0, workspace, 10"

          # Move active window to a workspace with mainMod + SHIFT + [0-9]
          "$mainMod SHIFT, 1, hy3:movetoworkspace, 1"
          "$mainMod SHIFT, 2, hy3:movetoworkspace, 2"
          "$mainMod SHIFT, 3, hy3:movetoworkspace, 3"
          "$mainMod SHIFT, 4, hy3:movetoworkspace, 4"
          "$mainMod SHIFT, 5, hy3:movetoworkspace, 5"
          "$mainMod SHIFT, 6, hy3:movetoworkspace, 6"
          "$mainMod SHIFT, 7, hy3:movetoworkspace, 7"
          "$mainMod SHIFT, 8, hy3:movetoworkspace, 8"
          "$mainMod SHIFT, 9, hy3:movetoworkspace, 9"
          "$mainMod SHIFT, 0, hy3:movetoworkspace, 10"

          # Example special workspace (scratchpad)
          "$mainMod, S, togglespecialworkspace, magic"
          "$mainMod SHIFT, S, hy3:movetoworkspace, special:magic"

          # Scroll through existing workspaces with mainMod + scroll
          "$mainMod, mouse_down, workspace, e-1"
          "$mainMod, mouse_up, workspace, e+1"

          # Make window fullscreen or fake fullscreen
          "$mainMod, f, fullscreen, 0"
          "$mainMod SHIFT, f, fakefullscreen,"
        ];

        # Move/resize windows with mainMod + LMB/RMB and dragging
        bindm = [
          "$mainMod, mouse:272, hy3:movewindow"
          "$mainMod, mouse:273, resizewindow"
        ];

        # https://wiki.hyprland.org/Configuring/Binds/#switches
        bindl = [
          # trigger when the switch is turning on
          '', switch:on:Lid Switch, exec, hyprctl keyword monitor "eDP-1, disable"''

          # trigger when the switch is turning off
          '', switch:off:Lid Switch, exec, hyprctl keyword monitor "eDP-1, preferred, auto, auto"''
        ];

        plugin.hy3 = {
          tabs = {
            text_font = "monospace";
          };

          autotile = {
            enable = true;
            trigger_width = 800;
            trigger_height = 500;
          };
        };
      };

      plugins = [ pkgs.hyprlandPlugins.hy3 ];
    };

    programs = {
      hyprlock = {
        enable = true;
        settings = {
          background = {
            path = "${wallpaper}";

            blur_passes = 2;
            contrast = 1;
            brightness = 0.5;
            vibrancy = 0.2;
            vibrancy_darkness = 0.2;
          };

          general = {
            no_fade_in = true;
            no_fade_out = true;
            hide_cursor = true;

            grace = 0;
          };

          # From: https://wiki.hyprland.org/Hypr-Ecosystem/hyprlock/#input-field
          input-field = {
            size = "200, 50";
            outline_thickness = 3;
            dots_size = 0.33; # Scale of input-field height, 0.2 - 0.8
            dots_spacing = 0.15; # Scale of dots' absolute size, 0.0 - 1.0
            dots_center = false;
            dots_rounding = -1; # -1 default circle, -2 follow input-field rounding
            outer_color = "rgb(151515)";
            inner_color = "rgb(200, 200, 200)";
            font_color = "rgb(10, 10, 10)";
            fade_on_empty = true;
            fade_timeout = 1000; # Milliseconds before fade_on_empty is triggered.
            placeholder_text = "<i>Input Password...</i>"; # Text rendered in the input box when it's empty.
            hide_input = false;
            rounding = -1; # -1 means complete rounding (circle/oval)
            check_color = "rgb(204, 136, 34)";
            fail_color = "rgb(204, 34, 34)"; # if authentication failed, changes outer_color and fail message color
            fail_text = "<i>$FAIL <b>($ATTEMPTS)</b></i>"; # can be set to empty
            fail_timeout = 2000; # milliseconds before fail_text and fail_color disappears
            fail_transition = 300; # transition time in ms between normal outer_color and fail_color
            capslock_color = -1;
            numlock_color = -1;
            bothlock_color = -1; # when both locks are active. -1 means don't change outer color (same for above)
            invert_numlock = false; # change color if numlock is off
            swap_font_color = false; # see below

            position = "0, -20";
            halign = "center";
            valign = "center";
          };
        };
      };

      waybar = {
        enable = true;

        systemd = {
          enable = true;
          target = "hyprland-session.target";
        };

        settings = [
          {
            height = 30;
            spacing = 6;
            layer = "top";
            position = "top";
            modules-left = [ "hyprland/workspaces" ];
            modules-center = [ "hyprland/window" ];
            modules-right = [
              "pulseaudio"
              "backlight"
              "battery"
              "clock"
              "tray"
            ];

            tray.spacing = 10;

            backlight = {
              format = "{icon} {percent}%";
              format-icons = [
                "󰃚"
                "󰃛"
                "󰃜"
                "󰃝"
                "󰃞"
                "󰃟"
                "󰃠"
              ];
              on-scroll-down = "${pkgs.light}/bin/light -T 0.618";
              on-scroll-up = "${pkgs.light}/bin/light -T 1.618";
            };

            battery = {
              states = {
                warning = 25;
                critical = 15;
              };

              format = "{icon} {capacity}%";
              format-charging = "󰂉 {capacity}%";
              format-plugged = "󰚥 {capacity}%";
              format-alt = "{icon} {time}";

              format-icons = [
                "󰁺"
                "󰁻"
                "󰁼"
                "󰁽"
                "󰁾"
                "󰁿"
                "󰂀"
                "󰂁"
                "󰂂"
                "󰁹"
              ];
            };

            clock = {
              tooltip-format = ''
                <big>{:%Y %B}</big>
                <tt><small>{calendar}</small></tt>'';
              format = "󱑒 {:%Y-%m-%d %H:%M}";
            };

            "hyprland/window" = {
              "max-length" = 200;
              "separate-outputs" = true;
            };

            "hyprland/workspaces" = {
              "on-scroll-up" = "hyprctl dispatch workspace e-1";
              "on-scroll-down" = "hyprctl dispatch workspace e+1";
            };

            network = {
              format-wifi = "󰖩 {essid}";
              format-ethernet = "{ipaddr}/{cidr} 󰈀";
              format-linked = "{ifname} (No IP)";
              format-disconnected = "Disconnected";
              format-alt = "{ifname}: {ipaddr}/{cidr}";
            };

            pulseaudio = {
              format = "{icon} {volume}%";
              format-muted = "󰖁";
              format-icons = {
                default = [
                  "󰕿"
                  "󰖀"
                  "󰕾"
                ];
              };

              on-click = "${pkgs.pamixer}/bin/pamixer -t";
              on-click-right = "${pkgs.pamixer}/bin/pamixer --default-source -t";
              on-scroll-down = "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -2dB";
              on-scroll-up = "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +2dB";
              tooltip = false;
            };
          }
        ];

        style = ''
          @keyframes blink-critical {
              0% {
                  color: rgb(237, 237, 237);
                  text-shadow: 0em 0em 0.5em rgba(255, 48, 48, 1),
                  0em 0em 0.5em rgba(255, 48, 48, 1),
                  0em 0em 0.5em rgba(255, 48, 48, 1),
                  0em 0em 0.5em rgba(255, 48, 48, 1);
              }
              50% {
                  color: rgba(255, 48, 48, 1);
                  text-shadow: 0em 0em 0.5em rgba(255, 48, 48, 0),
                  0em 0em 0.5em rgba(255, 48, 48, 0);
              }
              100% {
                  color: rgb(237, 237, 237);
                  text-shadow: 0em 0em 0.5em rgba(255, 48, 48, 1),
                  0em 0em 0.5em rgba(255, 48, 48, 1),
                  0em 0em 0.5em rgba(255, 48, 48, 1),
                  0em 0em 0.5em rgba(255, 48, 48, 1);
          }
          }

          /* COLORS */
          /*
          @define-color bg #000000;
          @define-color fg #EDEDED;
          @define-color green_accent #41CC4A;
          @define-color blue_accent #1E66F5;
          @define-color warning #FFB23F;
          @define-color critical #FF3030;
          */

          /* Dracula colors */
          /*
          @define-color bg rgba(30, 31, 41, 230);
          @define-color fg #f8f8f2;
          @define-color green_accent #50fa7b;
          @define-color blue_accent #8be9fd;
          @define-color warning #f1fa8c;
          @define-color critical #ff5555;
          */

          /* Selenized Black colors */
          /*
          @define-color bg #181818;
          @define-color fg #dedede;
          @define-color green_accent #70b433;
          @define-color blue_accent #368aeb;
          @define-color warning #dbb32d;
          @define-color critical #ed4a46;
          */

          /* Gruvbox Dark colors */
          @define-color bg #282828;
          @define-color fg #ebdbb2;
          @define-color green_accent #98971a;
          @define-color blue_accent #458588;
          @define-color warning #d79921;
          @define-color critical #cc241d;

          /* Reset all styles */
          * {
              border: none;
              min-height: 0;
              margin: 0em 0.3em 0em 0.3em;
          }

          /* The whole bar */
          #waybar {
              background: @bg;
              color: @fg;
              /* font-family: "JetBrains Mono", "Material Design Icons"; */
              font-family: "monospace";
              font-size: 15px;
              font-weight: bold;
              border-radius: 0;
          }

          /* Each module */
          #backlight,
          #battery,
          #clock,
          #network,
          #pulseaudio,
          #tray {
              padding-left: 0.4em;
              padding-right: 0.4em;
          }

          #battery.warning:not(.charging) {
              background-color: @bg;
              color: @warning;
          }

          #battery.critical:not(.charging) {
              color: @critical;
              background: @bg;
              text-shadow: 0em 0em 0.5em @critical,
              0em 0em 0.5em @critical;
              animation: blink-critical 2.5s infinite;
          }

          button.flat {
              transition: all 200ms cubic-bezier(0.25, 0.46, 0.45, 0.94);
          }

          #workspaces button {
              font-weight: bold;
              padding: 0;
              opacity: 0.3;
              background: none;
              font-size: 1em;
          }

          /* #workspaces button.focused { */
          #workspaces button.active {
              background: @bg;
              color: @fg;
              opacity: 1;
              padding: 0 0;
              text-shadow: 0em 0em 0.5em @fg,
              0em 0em 0.5em @fg;
          }

          #workspaces #sway-workspace-1 {
              text-shadow: 0em 0em 0.5em @fg,
              0em 0em 0.5em @fg,
              0em 0em 0.5em @fg;
          }

          #workspaces #sway-workspace-2, #workspaces #sway-workspace-3, #workspaces #sway-workspace-4 {
              text-shadow: 0em 0em 0.5em @fg;
          }

          #workspaces button.urgent {
              border-color: @critical;
              color: @critical;
              opacity: 1;
          }

          #window {
              margin-right: 40px;
              margin-left: 40px;
              font-weight: bold;
          }

          #pulseaudio {
              background: @bg;
              color: @fg;
          }

          #pulseaudio.muted {
              background-color: @critical;
              color: @bg;
          }

          #pulseaudio.source-muted {
              background-color: @warning;
              color: @bg;
          }

          #tray {
              background-color: @bg;
              color: @fg;
          }
        '';
      };
    };

    services = {
      hypridle = {
        enable = true;
        settings = {
          general = {
            lock_cmd = "${pkgs.procps}/bin/pidof hyprlock || ${pkgs.hyprlock}/bin/hyprlock"; # avoid starting multiple hyprlock instances.
            before_sleep_cmd = "${pkgs.systemd}/bin/loginctl lock-session";
            after_sleep_cmd = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
          };

          listener = [
            {
              # Turn off screen after two seconds of inactivity when locked
              timeout = 2;
              on-timeout = "${pkgs.procps}/bin/pidof hyprlock && ${pkgs.hyprland}/bin/hyprctl dispatch dpms off";
              on-resume = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
            }
            {
              timeout = 900; # 15 min
              on-timeout = "${pkgs.brightnessctl}/bin/brightnessctl -s set 10"; # set monitor backlight to minimum, avoid 0 on OLED monitor.
              on-resume = "${pkgs.brightnessctl}/bin/brightnessctl -r"; # monitor backlight restore.
            }
            {
              timeout = 910;
              on-timeout = "${pkgs.hyprland}/bin/hyprctl dispatch dpms off";
              on-resume = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
            }
            {
              timeout = 920;
              on-timeout = "${pkgs.systemd}/bin/loginctl lock-session";
            }
          ];
        };
      };

      hyprpaper = {
        enable = true;
        settings = {
          preload = "${wallpaper}";
          wallpaper = ", ${wallpaper}";
        };
      };

      kanshi.systemdTarget = "hyprland-session.target";
    };
  };
}
