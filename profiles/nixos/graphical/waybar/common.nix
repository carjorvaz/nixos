{ pkgs, lib, ... }:

{
  home-manager.users.cjv.programs.waybar = {
    enable = true;
    systemd.enable = true;

    settings.mainBar = {
      height = 30;
      spacing = 6;
      layer = "top";
      position = "top";

      modules-right = [
        "tray"
        "network"
        "pulseaudio"
        "backlight"
        "battery"
        "clock"
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

        tooltip = false;
      };

      battery = {
        states = {
          warning = 25;
          critical = 10;
        };

        format = "{icon} {capacity}%";
        format-plugged = "󰚥 {capacity}%";
        format-alt = "{icon} {time}";

        format-icons = {
          charging = [
            "󰢜"
            "󰂆"
            "󰂇"
            "󰂈"
            "󰢝"
            "󰂉"
            "󰢞"
            "󰂊"
            "󰂋"
            "󰂅"
          ];

          default = [
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

        tooltip-format-discharging = "{power:>1.2f}W↓ {capacity}%";
        tooltip-format-charging = "{power:>1.2f}W↑ {capacity}%";

        interval = 5;
      };

      clock = {
        tooltip-format = ''
          <big>{:%Y %B}</big>
          <tt><small>{calendar}</small></tt>'';
        format = "󱑒 {:%Y-%m-%d %H:%M}";
      };

      network = {
        format = "{icon}";
        format-alt = "{ifname}: {ipaddr}/{cidr}";
        format-wifi = "{icon}  {essid}";
        format-ethernet = "󰈀 {ipaddr}/{cidr}";
        format-disconnected = "󰤮 Disconnected";

        format-icons = [
          "󰤯"
          "󰤟"
          "󰤢"
          "󰤥"
          "󰤨"
        ];

        tooltip-format-wifi = "{essid} ({frequency} GHz)\n⇣{bandwidthDownBytes}  ⇡{bandwidthUpBytes}";
        tooltip-format-ethernet = "⇣{bandwidthDownBytes}  ⇡{bandwidthUpBytes}";

        on-click-right = "${pkgs.foot}/bin/foot ${pkgs.networkmanager}/bin/nmtui";

        interval = 3;
        spacing = 1;
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
    };

    style = lib.mkOrder 200 ''
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

      /* TODO move to separate files */
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

      /* Modus Operandi light theme colors */
      /*
      @define-color bg #ffffff;
      @define-color fg #000000;
      @define-color accent #0058a3;
      @define-color warning #a45e00;
      @define-color critical #d03c3c;
      */

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
}
