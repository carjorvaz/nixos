{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./common.nix ];

  services.xserver.windowManager.i3 = {
    enable = true;
    extraPackages = with pkgs; [ st ];
  };

  programs = {
    slock.enable = true;

    # To lock: loginctl lock-session
    # https://discourse.nixos.org/t/slock-when-suspend/22457
    xss-lock = {
      enable = true;
      lockerCommand = "/run/wrappers/bin/slock";
    };
  };

  home-manager.users.cjv = {
    programs = {
      i3status-rust.enable = true;

      rofi = {
        enable = true;
        cycle = true;
        terminal = "${pkgs.st}/bin/st";
        plugins = with pkgs; [ rofi-calc ];
      };
    };

    xsession.windowManager.i3 = {
      enable = true;

      config = rec {
        modifier = "Mod4";
        terminal = "st";

        defaultWorkspace = "1";

        # Find out class with xprop
        assigns = {
          "2" = [ { class = "Emacs"; } ];
          "7" = [ { class = "betterbird"; } ];
          "8" = [ { class = "Signal"; } ];
          "9" = [ { class = "discord"; } ];
        };

        keybindings =
          let
            modifier = config.home-manager.users.cjv.xsession.windowManager.i3.config.modifier;
          in
          lib.mkOptionDefault {
            "${modifier}+1" = "workspace number 1";
            "${modifier}+2" = "workspace number 2";
            "${modifier}+3" = "workspace number 3";
            "${modifier}+4" = "workspace number 4";
            "${modifier}+5" = "workspace number 5";
            "${modifier}+6" = "workspace number 6";
            "${modifier}+7" = "workspace number 7";
            "${modifier}+8" = "workspace number 8";
            "${modifier}+9" = "workspace number 9";

            "${modifier}+Shift+1" = "move container to workspace number 1";
            "${modifier}+Shift+2" = "move container to workspace number 2";
            "${modifier}+Shift+3" = "move container to workspace number 3";
            "${modifier}+Shift+4" = "move container to workspace number 4";
            "${modifier}+Shift+5" = "move container to workspace number 5";
            "${modifier}+Shift+6" = "move container to workspace number 6";
            "${modifier}+Shift+7" = "move container to workspace number 7";
            "${modifier}+Shift+8" = "move container to workspace number 8";
            "${modifier}+Shift+9" = "move container to workspace number 9";

            "${modifier}+minus" = "scratchpad show";
            "${modifier}+Shift+minus" = "move scratchpad";

            "${modifier}+Shift+q" = "kill";

            "${modifier}+r" = "mode resize";
            "${modifier}+b" = "splith";
            "${modifier}+v" = "splitv";

            "${modifier}+e" = "layout toggle split";
            "${modifier}+s" = "layout stacking";
            "${modifier}+w" = "layout tabbed";

            "${modifier}+Shift+space" = "floating toggle";
            "${modifier}+space" = "focus mode_toggle";
            "${modifier}+f" = "fullscreen toggle";
            "${modifier}+a" = "focus parent";

            "${modifier}+Left" = "focus left";
            "${modifier}+Down" = "focus down";
            "${modifier}+Up" = "focus up";
            "${modifier}+Right" = "focus right";

            "${modifier}+h" = "focus left";
            "${modifier}+j" = "focus down";
            "${modifier}+k" = "focus up";
            "${modifier}+l" = "focus right";

            "${modifier}+Shift+Left" = "move left";
            "${modifier}+Shift+Down" = "move down";
            "${modifier}+Shift+Up" = "move up";
            "${modifier}+Shift+Right" = "move right";

            "${modifier}+Shift+h" = "move left";
            "${modifier}+Shift+j" = "move down";
            "${modifier}+Shift+k" = "move up";
            "${modifier}+Shift+l" = "move right";

            "${modifier}+Shift+c" = "reload";

            "${modifier}+Return" = "exec ${config.home-manager.users.cjv.xsession.windowManager.i3.config.terminal}";
            "${modifier}+Escape" = "exec slock";

            # Rofi
            "${modifier}+d" = "exec rofi -modes combi -show combi";
            "${modifier}+Shift+d" = "exec rofi -modes drun -show drun";
            "${modifier}+c" = "exec rofi -modes calc -show calc";
            "${modifier}+x" = "exec rofi -modes calc -show calc"; # TODO emoji

            # Screenshots
            "Print" = "exec ${pkgs.flameshot}/bin/flameshot gui";
            "${modifier}+p" = "exec ${pkgs.flameshot}/bin/flameshot gui";

            # Brightness - logarithmic scale
            "XF86MonBrightnessDown" = "exec ${pkgs.light}/bin/light -T 0.618";
            "XF86MonBrightnessUp" = "exec ${pkgs.light}/bin/light -T 1.618";

            # Audio - logarithmic scale
            "XF86AudioRaiseVolume" = "exec '${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +2dB'";
            "XF86AudioLowerVolume" = "exec '${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -2dB'";
            "XF86AudioMute" = "exec '${pkgs.pamixer}/bin/pamixer -t'";
            "XF86AudioMicMute" = "exec ${pkgs.pamixer}/bin/pamixer --default-source -t";

            # Move to custom workspace
            "${modifier}+t" = "exec ${pkgs.i3}/bin/i3-msg workspace $(i3-msg -t get_workspaces | ${pkgs.jq}/bin/jq -r '.[].name' | rofi -dmenu -p 'Go to workspace:' )";
            "${modifier}+Shift+t" = "exec ${pkgs.i3}/bin/i3-msg move container to workspace $(i3-msg -t get_workspaces | ${pkgs.jq} -r '.[].name' | rofi -dmenu -p 'Move to workspace:')";
          };

        bars = [
          {
            statusCommand = "${pkgs.i3status-rust}/bin/i3status-rs ~/.config/i3status-rust/config-top.toml";
            position = "top";
            fonts = {
              size = 12.0;
              names = [ "monospace" ];
            };
          }
        ];
      };
    };
  };
}
