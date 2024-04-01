{ config, inputs, lib, pkgs, ... }:

# TODO:
# - use hyprlandPlugins and try out hy3; will use sway until then
{
  imports = [ ./common.nix ./selenized.nix ./wayland.nix ];

  programs.hyprland = {
    enable = true;
    package = pkgs.unstable.hyprland;
  };

  # Swaylock won't work without this.
  security.pam.services.swaylock = { };

  systemd.user.services = {
    gammastep.wantedBy = lib.mkForce [ "hyprland-session.target" ];
  };

  home-manager.users.cjv = {
    wayland.windowManager.hyprland = {
      enable = true;
      # package = pkgs.unstable.hyprland;
      xwayland.enable = true;

      # Whether to enable hyprland-session.target on hyprland startup
      systemd.enable = true;

      settings = {
        # https://wiki.hyprland.org/Configuring/Monitors/

        # TODO Per host configuration if at all
        # monitor = [ "HDMI-A-1,preferred,auto,1" ",preferred,auto,1" ];

        # See https://wiki.hyprland.org/Configuring/Keywords/ for more

        # Execute your favorite apps at launch
        exec-once = [
          "nextcloud --background"
          "${pkgs.swaybg}/bin/swaybg -m fill -i ~/Pictures/wallpaper.png"
        ];

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
            scroll_factor = "0.4";
          };

          sensitivity = 0; # -1.0 - 1.0, 0 means no modification.
        };

        general = {
          gaps_in = 5;
          gaps_out = 20;
          border_size = 2;

          "col.active_border" =
            lib.mkDefault "rgba(33ccffee) rgba(00ff99ee) 45deg";
          "col.inactive_border" = lib.mkDefault "rgba(595959aa)";

          layout = "dwindle";
          # layout = "hy3";
        };

        decoration = {
          rounding = 10;

          blur = {
            enabled = lib.mkDefault true;
            size = 3;
            passes = 1;

            vibrancy = 0.1696; # TODO check this
          };

          drop_shadow = lib.mkDefault true;
          shadow_range = lib.mkDefault 4;
          shadow_render_power = 3;
          "col.shadow" = lib.mkDefault "rgba(1a1a1aee)";
        };

        # https://wiki.hyprland.org/Configuring/Animations/ for more
        animations = {
          enabled = lib.mkDefault true;

          bezier = "myBezier, 0.05, 0.9, 0.1, 1.05";

          animation = [
            "windows, 1, 7, myBezier"
            "windowsOut, 1, 7, default, popin 80%"
            "border, 1, 10, default"
            "borderangle, 1, 8, default"
            "fade, 1, 7, default"
            "workspaces, 1, 6, default"
          ];
        };

        # https://wiki.hyprland.org/Configuring/Dwindle-Layout/
        dwindle = {
          pseudotile =
            true; # master switch for pseudotiling. Enabling is bound to mainMod + P in the keybinds section below
          preserve_split = true; # you probably want this
        };

        # https://wiki.hyprland.org/Configuring/Master-Layout/
        master = { new_is_master = true; };

        gestures = {
          workspace_swipe = false; # TODO check
        };

        # Set to 0 to disable the anime mascot wallpapers
        misc.force_default_wallpaper = 0;

        # Per-device config
        # https://wiki.hyprland.org/Configuring/Keywords/#per-device-input-configs
        "device:synps/2-synaptics-touchpad".accel_profile = "adaptive";

        # Example windowrule v1
        # windowrule = float, ^(kitty)$
        # Example windowrule v2
        # windowrulev2 = float,class:^(kitty)$,title:^(kitty)$
        # See https://wiki.hyprland.org/Configuring/Window-Rules/ for more

        windowrulev2 = lib.mkDefault
          "nomaximizerequest, class:.*"; # You'll probably like this.

        # See https://wiki.hyprland.org/Configuring/Keywords/ for more
        "$mainMod" = "SUPER";

        # Example binds, see https://wiki.hyprland.org/Configuring/Binds/ for more
        bind = [
          "$mainMod, ESCAPE, exec, swaylock"
          "$mainMod, RETURN, exec, $terminal"
          "$mainMod SHIFT, Q, killactive,"
          "$mainMod SHIFT, E, exit,"
          "$mainMod SHIFT, space, togglefloating,"
          "$mainMod, P, pseudo," # dwindle
          "$mainMod, V, togglesplit," # dwindle

          # Brightness
          ", XF86MonBrightnessDown, exec, ${pkgs.light}/bin/light -T 0.72"
          ", XF86MonBrightnessUp, exec, ${pkgs.light}/bin/light -T 1.4"

          # Audio
          ", XF86AudioRaiseVolume, exec, ${pkgs.pamixer}/bin/pamixer --increase 5"
          "ALT, XF86AudioRaiseVolume, exec, ${pkgs.pamixer}/bin/pamixer --increase 1"
          ", XF86AudioLowerVolume, exec, ${pkgs.pamixer}/bin/pamixer --decrease 5"
          "ALT, XF86AudioLowerVolume, exec, ${pkgs.pamixer}/bin/pamixer --decrease 1"
          ", XF86AudioMute, exec, ${pkgs.pamixer}/bin/pamixer -t"
          ", XF86AudioMicMute, exec, ${pkgs.pamixer}/bin/pamixer --default-source -t"

          # Rofi
          "$mainMod, D, exec, $menu -modes combi -show combi"
          "$mainMod SHIFT, D, exec, $menu -modes drun -show drun"
          "$mainMod, C, exec, $menu -modes calc -show calc"

          # Screenshots
          ", Print, exec, ${pkgs.grimblast}/bin/grimblast --notify copy area"
          "Shift, Print, exec, ${pkgs.grimblast}/bin/grimblast --notify copysave area /tmp/$(${pkgs.coreutils}/bin/date +'%H:%M:%S.png')"

          # Move focus with mainMod + arrow keys
          "$mainMod, left, movefocus, l"
          "$mainMod, right, movefocus, r"
          "$mainMod, up, movefocus, u"
          "$mainMod, down, movefocus, d"

          # Move window with mainMod + arrow keys
          "$mainMod SHIFT, left, movewindow, l"
          "$mainMod SHIFT, right, movewindow, r"
          "$mainMod SHIFT, up, movewindow, u"
          "$mainMod SHIFT, down, movewindow, d"

          # Move focus with mainMod + vim keys
          "$mainMod, h, movefocus, l"
          "$mainMod, j, movefocus, d"
          "$mainMod, k, movefocus, u"
          "$mainMod, l, movefocus, r"

          # Move window with mainMod + vim keys
          "$mainMod SHIFT, h, movewindow, l"
          "$mainMod SHIFT, j, movewindow, d"
          "$mainMod SHIFT, k, movewindow, u"
          "$mainMod SHIFT, l, movewindow, r"

          # # Move focus with mainMod + arrow keys
          # "$mainMod, left, hy3:movefocus, l"
          # "$mainMod, right, hy3:movefocus, r"
          # "$mainMod, up, hy3:movefocus, u"
          # "$mainMod, down, hy3:movefocus, d"

          # # Move window with mainMod + arrow keys
          # "$mainMod SHIFT, left, hy3:movewindow, l"
          # "$mainMod SHIFT, right, hy3:movewindow, r"
          # "$mainMod SHIFT, up, hy3:movewindow, u"
          # "$mainMod SHIFT, down, hy3:movewindow, d"

          # # Move focus with mainMod + vim keys
          # "$mainMod, h, hy3:movefocus, l"
          # "$mainMod, j, hy3:movefocus, d"
          # "$mainMod, k, hy3:movefocus, u"
          # "$mainMod, l, hy3:movefocus, r"

          # # Move window with mainMod + vim keys
          # "$mainMod SHIFT, h, hy3:movewindow, l"
          # "$mainMod SHIFT, j, hy3:movewindow, d"
          # "$mainMod SHIFT, k, hy3:movewindow, u"
          # "$mainMod SHIFT, l, hy3:movewindow, r"

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
          "$mainMod SHIFT, 1, movetoworkspacesilent, 1"
          "$mainMod SHIFT, 2, movetoworkspacesilent, 2"
          "$mainMod SHIFT, 3, movetoworkspacesilent, 3"
          "$mainMod SHIFT, 4, movetoworkspacesilent, 4"
          "$mainMod SHIFT, 5, movetoworkspacesilent, 5"
          "$mainMod SHIFT, 6, movetoworkspacesilent, 6"
          "$mainMod SHIFT, 7, movetoworkspacesilent, 7"
          "$mainMod SHIFT, 8, movetoworkspacesilent, 8"
          "$mainMod SHIFT, 9, movetoworkspacesilent, 9"
          "$mainMod SHIFT, 0, movetoworkspacesilent, 10"

          # Example special workspace (scratchpad)
          "$mainMod, S, togglespecialworkspace, magic"
          "$mainMod SHIFT, S, movetoworkspacesilent, special:magic"

          # Scroll through existing workspaces with mainMod + scroll
          "$mainMod, mouse_down, workspace, e+1"
          "$mainMod, mouse_up, workspace, e-1"

          # Make window fullscreen or fake fullscreen
          "$mainMod, f, fullscreen, 0"
          "$mainMod SHIFT, f, fakefullscreen,"
        ];

        # Move/resize windows with mainMod + LMB/RMB and dragging
        bindm = [
          "$mainMod, mouse:272, movewindow"
          "$mainMod, mouse:273, resizewindow"
        ];

      };

      # plugins = [
      #   pkgs.unstable.hyprlandPlugins.hy3
      # ];
    };

    programs = {
      waybar = {
        enable = true;

        systemd = {
          enable = true;
          target = "hyprland-session.target";
        };

        settings = [{
          height = 30;
          spacing = 6;
          layer = "top";
          position = "top";
          modules-left = [ "hyprland/workspaces" ];
          modules-center = [ "hyprland/window" ];
          modules-right =
            [ "pulseaudio" "backlight" "network" "battery" "clock" "tray" ];

          tray.spacing = 10;

          backlight = {
            format = "{icon} {percent}%";
            format-icons = [ "󰃚" "󰃛" "󰃜" "󰃝" "󰃞" "󰃟" "󰃠" ];
          };

          battery = {
            # TODO watts e time left? (mas só na tooltip)
            states = {
              warning = 25;
              critical = 15;
            };

            format = "{icon} {capacity}%";
            format-charging = "󰂉 {capacity}%";
            format-plugged = "󰚥 {capacity}%";
            format-alt = "{icon} {time}";

            format-icons = [ "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
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
            "on-scroll-up" = "hyprctl dispatch workspace e+1";
            "on-scroll-down" = "hyprctl dispatch workspace e-1";
          };

          network = {
            format-wifi = "󰖩 {essid}";
            format-ethernet = "{ipaddr}/{cidr} 󰈀";
            format-linked = "{ifname} (No IP)";
            format-disconnected = "Disconnected";
            format-alt = "{ifname}: {ipaddr}/{cidr}";
          };

          # TODO mute unmute com right click
          pulseaudio = {
            format = "{icon} {volume}%";
            format-muted = "󰖁";
            format-icons = { default = [ "󰕿" "󰖀" "󰕾" ]; };
            on-click = "${pkgs.pavucontrol}/bin/pavucontrol";
            tooltip = false;
          };
        }];

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
          @define-color bg #181818;
          @define-color fg #dedede;
          @define-color green_accent #70b433;
          @define-color blue_accent #368aeb;
          @define-color warning #dbb32d;
          @define-color critical #ed4a46;

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
      kanshi.systemdTarget = "hyprland-session.target";
      swayidle.timeouts = [
        {
          timeout = 300;
          command = "${pkgs.swaylock}/bin/swaylock";
        }
        {
          timeout = 2;
          command =
            "if ${pkgs.procps}/bin/pgrep swaylock; then ${pkgs.hyprland}/bin/hyprctl dispatch dpms off; fi";
          resumeCommand = "${pkgs.hyprland}/bin/hyprctl dispatch dpms on";
        }
      ];
    };
  };
}
