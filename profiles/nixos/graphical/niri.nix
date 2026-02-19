{
  inputs,
  lib,
  pkgs,
  config,
  ...
}:

# Reference:
# - https://github.com/sodiboo/niri-flake/blob/main/docs.md
# - https://github.com/sodiboo/system/blob/main/personal/niri.mod.nix
let
  my-lockscreen = pkgs.writeShellScriptBin "my-lockscreen" ''
    # Exit if swaylock is already running (prevents double-lock on suspend)
    ${pkgs.procps}/bin/pgrep -x swaylock && exit 0

    # Launch swayidle to switch off screen after 5 seconds
    ${pkgs.swayidle}/bin/swayidle -w \
      timeout 5 '${pkgs.niri}/bin/niri msg action power-off-monitors' \
      resume '${pkgs.niri}/bin/niri msg action power-on-monitors' &

    # Lock the screen
    ${pkgs.swaylock}/bin/swaylock

    # Kill swayidle after unlocking
    ${pkgs.procps}/bin/pkill --newest swayidle
  '';
in
{
  imports = [
    ./swaylock.nix
    ./themes/gruvbox.nix
    ./waybar/niri.nix
    ./wayland.nix
  ];

  nixpkgs.overlays = [ inputs.niri.overlays.niri ];
  niri-flake.cache.enable = true;

  programs = {
    light.enable = true;

    niri = {
      enable = true;
      package = pkgs.niri-stable;
    };
  };

  users.users.cjv.extraGroups = [ "video" ]; # For rootless light.

  environment.systemPackages = with pkgs; [
    alacritty
    xwayland-satellite
  ];

  home-manager.users.cjv = {
    programs = {
      niri.settings = {
        binds = {
          "Mod+Escape".action.spawn = [
            "loginctl"
            "lock-session"
          ];
          "Mod+Return".action.spawn = config.graphical.defaultTerminal;
          "Mod+Shift+Q".action.close-window = [ ];
          "Mod+Shift+E".action.quit = [ ];
          "Mod+Shift+Space".action.toggle-window-floating = [ ];

          # Brightness - logarithmic scale
          "XF86MonBrightnessDown".action.spawn-sh = "${pkgs.light}/bin/light -T 0.618";
          "XF86MonBrightnessUp".action.spawn-sh = "${pkgs.light}/bin/light -T 1.618";
          "Shift+XF86MonBrightnessDown".action.spawn-sh = "${pkgs.light}/bin/light -T 0.786";
          "Shift+XF86MonBrightnessUp".action.spawn-sh = "${pkgs.light}/bin/light -T 1.272";

          # Audio - logarithmic scale
          "XF86AudioLowerVolume".action.spawn-sh =
            "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -2dB";
          "XF86AudioRaiseVolume".action.spawn-sh =
            "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +2dB";
          "Shift+XF86AudioLowerVolume".action.spawn-sh =
            "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -1dB";
          "Shift+XF86AudioRaiseVolume".action.spawn-sh =
            "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +1dB";
          "XF86AudioMute".action.spawn-sh = "${pkgs.pamixer}/bin/pamixer -t";
          "XF86AudioMicMute".action.spawn-sh = "${pkgs.pamixer}/bin/pamixer --default-source -t";

          "Mod+Space".action.spawn = [
            "rofi"
            "-modes"
            "combi"
            "-combi-modes"
            "run,drun"
            "-show"
            "combi"
          ];
          "Mod+C".action.spawn = [
            "rofi"
            "-modes"
            "calc"
            "-show"
            "calc"
          ];

          # Org capture
          "Mod+X".action.spawn = [
            "emacsclient"
            "-e"
            "(+org-capture/open-frame nil \"i\")"
          ];
          "Mod+Shift+X".action.spawn = [
            "emacsclient"
            "-e"
            "(+org-capture/open-frame nil \"n\")"
          ];

          "Print".action.screenshot = [ ];
          "Mod+P".action.screenshot = [ ];

          # Notifications
          "Mod+N".action.spawn = [
            "${pkgs.mako}/bin/makoctl"
            "dismiss"
          ];
          "Mod+Shift+N".action.spawn = [
            "${pkgs.mako}/bin/makoctl"
            "dismiss"
            "--all"
          ];
          "Mod+Ctrl+N".action.spawn-sh = "${pkgs.mako}/bin/makoctl mode -t do-not-disturb; ${pkgs.procps}/bin/pkill --signal RTMIN+9 waybar || true";

          "Mod+H".action.focus-column-left = [ ];
          "Mod+J".action.focus-window-or-workspace-down = [ ];
          "Mod+K".action.focus-window-or-workspace-up = [ ];
          "Mod+L".action.focus-column-right = [ ];

          "Mod+Left".action.focus-column-left = [ ];
          "Mod+Down".action.focus-window-or-workspace-down = [ ];
          "Mod+Up".action.focus-window-or-workspace-up = [ ];
          "Mod+Right".action.focus-column-right = [ ];

          "Mod+Home".action.focus-column-first = [ ];
          "Mod+End".action.focus-column-last = [ ];

          "Mod+Shift+H".action.move-column-left = [ ];
          "Mod+Shift+J".action.move-window-down-or-to-workspace-down = [ ];
          "Mod+Shift+K".action.move-window-up-or-to-workspace-up = [ ];
          "Mod+Shift+L".action.move-column-right = [ ];

          "Mod+Shift+Left".action.move-column-left = [ ];
          "Mod+Shift+Down".action.move-window-down-or-to-workspace-down = [ ];
          "Mod+Shift+Up".action.move-window-up-or-to-workspace-up = [ ];
          "Mod+Shift+Right".action.move-column-right = [ ];

          "Mod+Ctrl+J".action.move-workspace-down = [ ];
          "Mod+Ctrl+K".action.move-workspace-up = [ ];

          "Mod+Ctrl+Down".action.move-workspace-down = [ ];
          "Mod+Ctrl+Up".action.move-workspace-up = [ ];

          # "Mod+1".action.focus-workspace = 1;
          # "Mod+2".action.focus-workspace = 2;
          # "Mod+3".action.focus-workspace = 3;
          # "Mod+4".action.focus-workspace = 4;
          # "Mod+5".action.focus-workspace = 5;
          # "Mod+6".action.focus-workspace = 6;
          # "Mod+7".action.focus-workspace = 7;
          # "Mod+8".action.focus-workspace = 8;
          # "Mod+9".action.focus-workspace = 9;

          "Mod+F".action.maximize-column = [ ];
          "Mod+Shift+F".action.fullscreen-window = [ ];

          "Mod+Comma".action.focus-monitor-left = [ ];
          "Mod+Period".action.focus-monitor-right = [ ];

          "Mod+Shift+Comma".action.move-window-to-monitor-left = [ ];
          "Mod+Shift+Period".action.move-window-to-monitor-right = [ ];

          "Mod+O".action.toggle-overview = [ ];
          "Mod+W".action.toggle-column-tabbed-display = [ ];
        };

        hotkey-overlay.skip-at-startup = true;

        input = {
          focus-follows-mouse.max-scroll-amount = "0%";

          keyboard = {
            repeat-delay = 300;
            repeat-rate = 30;
          };

          mouse.accel-profile = "flat";

          touchpad = {
            accel-profile = "adaptive";
            click-method = "clickfinger";
            dwt = true;
            tap = false;
            scroll-factor = 0.2;
          };
        };

        layout = {
          always-center-single-column = true;
          empty-workspace-above-first = true;

          gaps = 10;
          border.width = 2;
        };

        prefer-no-csd = true;

        # Eye care concerns
        outputs."*".variable-refresh-rate = false;

        screenshot-path = "~/Pictures/Screenshots/%Y-%m-%dT%H:%M:%S.png";

        window-rules = [
          {
            matches = [{ title = "doom-capture"; }];
            open-floating = true;
          }
        ];
      };
    };

    services = {
      gammastep = {
        enable = true;
        tray = true;

        latitude = 38.7;
        longitude = -9.14;

        temperature = {
          day = 6500;
          night = 1200;
        };
      };

      mako = {
        enable = true;

        # Reference: https://github.com/basecamp/omarchy/blob/master/default/mako/core.ini
        settings = {
          anchor = "top-right";
          default-timeout = "10000";
          width = "420";
          outer-margin = "20";
          padding = "10,15";
          border-size = "2";
          max-icon-size = "32";
          font = "sans-serif 14px";

          "urgency=critical".default-timeout = 0;

          "mode=do-not-disturb".invisible = "true";
        };
      };

      swayidle = {
        enable = true;
        events = {
          before-sleep = "${pkgs.systemd}/bin/loginctl lock-session";
          lock = "${my-lockscreen}/bin/my-lockscreen";
        };
      };

      wpaperd.enable = true;
    };
  };
}
