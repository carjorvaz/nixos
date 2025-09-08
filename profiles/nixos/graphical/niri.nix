{ inputs, pkgs, ... }:

# Reference:
# - https://github.com/sodiboo/niri-flake/blob/main/docs.md
# - https://github.com/sodiboo/system/blob/main/personal/niri.mod.nix
let
  my-lockscreen = pkgs.writeShellScriptBin "my-lockscreen" ''
    # Get output names
    outputs=$(${pkgs.niri}/bin/niri msg outputs | ${pkgs.gnugrep}/bin/grep "Output" | ${pkgs.gnugrep}/bin/grep -o '([^)]*)' | ${pkgs.coreutils-full}/bin/tr -d '()')

    # Build output control commands
    off_cmd=""
    on_cmd=""
    for output in $outputs; do
      off_cmd+="${pkgs.niri}/bin/niri msg output $output off && "
      on_cmd+="${pkgs.niri}/bin/niri msg output $output on && "
    done
    off_cmd="''${off_cmd% && }"
    on_cmd="''${on_cmd% && }"

    # Launch swayidle with dynamic output control
    ${pkgs.swayidle}/bin/swayidle -w \
      timeout 5 "$off_cmd" \
      resume "$on_cmd" &

    # Lock the screen
    ${pkgs.swaylock}/bin/swaylock

    # Kill swayidle after unlocking
    ${pkgs.procps}/bin/pkill --newest swayidle
  '';
in
{
  imports = [
    ./swaylock.nix
    ./themes/modus-operandi.nix
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
          "Mod+Return".action.spawn = "foot";
          "Mod+Shift+Q".action.close-window = [ ];
          "Mod+Shift+E".action.quit = [ ];
          "Mod+Shift+Space".action.toggle-window-floating = [ ];

          # Brightness - logarithmic scale
          "XF86MonBrightnessDown".action.spawn-sh = "${pkgs.light}/bin/light -T 0.618";
          "XF86MonBrightnessUp".action.spawn-sh = "${pkgs.light}/bin/light -T 1.618";

          # Audio - logarithmic scale
          "XF86AudioLowerVolume".action.spawn-sh =
            "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -2dB";
          "XF86AudioRaiseVolume".action.spawn-sh =
            "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +2dB";
          "XF86AudioMute".action.spawn-sh = "${pkgs.pamixer}/bin/pamixer -t";
          "XF86AudioMicMute".action.spawn-sh = "${pkgs.pamixer}/bin/pamixer --default-source -t";

          "Mod+D".action.spawn = [
            "rofi"
            "-modes"
            "combi"
            "-show"
            "combi"
          ];
          "Mod+Shift+D".action.spawn = [
            "rofi"
            "-modes"
            "drun"
            "-show"
            "drun"
          ];
          "Mod+C".action.spawn = [
            "rofi"
            "-modes"
            "calc"
            "-show"
            "calc"
          ];

          "Print".action.screenshot = [ ];
          "Mod+P".action.screenshot = [ ];

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
            scroll-factor = 0.1;
          };
        };

        layout = {
          always-center-single-column = true;
          empty-workspace-above-first = true;

          gaps = 10;
          border.width = 2;
        };

        prefer-no-csd = true;

        screenshot-path = "~/Pictures/Screenshots/%Y-%m-%dT%H:%M:%S.png";
      };
    };

    services = {
      gammastep = {
        enable = true;
        tray = true;

        # latitude = 38.7;
        # longitude = -9.14;
        latitude = 51.5;
        longitude = -0.12;

        temperature = {
          day = 6500;
          night = 1200;
        };
      };

      mako.enable = true;

      swayidle = {
        enable = true;
        events = [
          {
            event = "before-sleep";
            command = "${my-lockscreen}/bin/my-lockscreen";
          }
          {
            event = "lock";
            command = "${my-lockscreen}/bin/my-lockscreen";
          }
        ];
      };

      wpaperd = {
        enable = true;
        settings.default.path = ./wallpaper.jpg;
      };
    };
  };
}
