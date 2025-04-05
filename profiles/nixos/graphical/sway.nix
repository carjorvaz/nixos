{
  config,
  pkgs,
  lib,
  ...
}:

let
  my-sway-lock = pkgs.writeShellScriptBin "my-sway-lock" ''
    # Launch swayidle to switch off screen after 5 seconds, if locked
    ${pkgs.swayidle}/bin/swayidle -w timeout 5 '${pkgs.sway}/bin/swaymsg "output * dpms off"' resume '${pkgs.sway}/bin/swaymsg "output * dpms on"' &

    # Lock the screen
    ${pkgs.swaylock}/bin/swaylock

    # Kill swayidle after unlocking
    ${pkgs.procps}/bin/pkill --newest swayidle
  '';
in
{
  imports = [ ./wayland.nix ];

  environment.systemPackages = with pkgs; [
    qt5.qtwayland

    # screenshot functionality
    grim
    slurp
    sway-contrib.grimshot
  ];

  services = {
    blueman.enable = true;
    dbus.enable = true;
    gnome.gnome-keyring.enable = true;

    # # Interesting possibility but I would rather have automatic screen turn off on my machines.
    # xserver.displayManager.gdm.enable = false;
    # greetd = {
    #   enable = true;
    #   settings = {
    #     default_session = {
    #       command = "${pkgs.greetd.tuigreet}/bin/tuigreet --time --cmd sway";
    #       user = "greeter";
    #     };
    #   };
    # };
  };

  xdg.portal = {
    enable = true;
    wlr.enable = true;
  };

  programs = {
    sway = {
      enable = true;
      wrapperFeatures.gtk = true;
    };

    dconf.enable = true;
    light.enable = true;
  };

  users.users.cjv.extraGroups = [ "video" ]; # For rootless light.

  security = {
    pam.loginLimits = [
      {
        domain = "@users";
        item = "rtprio";
        type = "-";
        value = 1;
      }
    ];

    polkit.enable = true;
  };

  systemd.user.services = {
    nextcloud-client.wantedBy = lib.mkForce [ "sway-session.target" ];
  };

  home-manager.users.cjv = {
    dconf = {
      enable = true;
      settings = {
        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-dark";
        };
      };
    };

    gtk = lib.mkDefault {
      enable = true;

      theme = {
        # Use `dconf watch /` to see the correct name
        package = pkgs.adw-gtk3;
        name = "adw-gtk3-dark";
      };

      iconTheme = {
        package = pkgs.adwaita-icon-theme;
        name = "Adwaita";
      };
    };

    qt = {
      enable = true;
      platformTheme.name = "kde";
      style.name = "breeze";
    };

    programs = {
      firefox.profiles.default.settings = {
        # https://www.reddit.com/r/swaywm/comments/1iuqclq/firefox_is_now_way_more_efficient_under_sway_it/
        "gfx.webrender.compositor.force-enabled" = true;
      };

      i3status-rust = {
        enable = true;
        bars.top = {
          icons = "material-nf";
          theme = "plain";
          blocks = [
            {
              block = "sound";
              max_vol = 100;
              headphones_indicator = true;
              device_kind = "sink";
              click = [
                {
                  button = "left";
                  cmd = "${pkgs.rofi-pulse-select}/bin/rofi-pulse-select sink";
                }
              ];

              # on_scroll_up = "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +2dB";
              # on_scroll_down = "${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -2dB";
            }
            {
              block = "time";
              interval = 5;
              format = " $timestamp.datetime(f:'%a %d/%m %R')";
            }
          ];
        };
      };

      swaylock = {
        enable = true;
        settings = {
          # Needed for fingerprint to work with swaylock.
          # Press enter than tap finger.
          ignore-empty-password = false;
          show-failed-attempts = true;

          font = "monospace";
          image = "${./wallpaper.jpg}";

          # https://github.com/swayos/swayos.github.io/blob/main/home/.swaylock/config
          color = "dcdccc55";
          indicator-radius = "100";
          indicator-thickness = "50";
          # layout-border-color = "00000022";
          line-color = "ffffff22";
          line-clear-color = "00000000";
          line-caps-lock-color = "00000000";
          line-ver-color = "00000000";
          line-wrong-color = "00000000";
          inside-color = "dcdccc55";
          # inside-ver-color = "dcdcdc55";
          ring-color = "dcdcdc55";
          ring-ver-color = "33445555";
          key-hl-color = "FFFFFF66";
          separator-color = "00000000";
          layout-bg-color = "00000000";
          layout-border-color = "00000000";
          inside-ver-color = "ffffff22";
          font-size = "24";
          text-color = "FFFFFFFF";
          text-clear-color = "FFFFFFFF";
          text-caps-lock-color = "FFFFFFFF";
          text-ver-color = "FFFFFFFF";
          text-wrong-color = "FFFFFFFF";
        };
      };
    };

    wayland.windowManager.sway = {
      enable = true;
      systemd.enable = true;

      wrapperFeatures = {
        base = true;
        gtk = true;
      };

      config = rec {
        modifier = "Mod4";
        terminal = "foot";

        defaultWorkspace = "workspace number 1";

        # Find name with: swaymsg -t get_tree
        assigns = {
          "2" = [ { app_id = "emacs"; } ];
          "7" = [ { app_id = "betterbird"; } ];
          "8" = [ { app_id = "signal"; } ];
          "9" = [ { app_id = "discord"; } ];
        };

        input = {
          "type:keyboard" = {
            xkb_layout = "us";
            xkb_options = "ctrl:nocaps";
            xkb_variant = "altgr-intl";
            repeat_delay = "300";
            repeat_rate = "30";
          };

          "type:pointer" = {
            accel_profile = "flat";
            pointer_accel = "0";
          };

          "type:touchpad" = {
            accel_profile = "adaptive";
            tap = "enabled";
            natural_scroll = "enabled";
            scroll_factor = "0.2";
          };
        };

        output = {
          "*".bg = lib.mkDefault "${./wallpaper.jpg} fill";

          "eDP-1".scale = "1.5";
        };

        keybindings =
          let
            modifier = config.home-manager.users.cjv.wayland.windowManager.sway.config.modifier;
          in
          lib.mkOptionDefault {
            "${modifier}+Escape" = "exec ${my-sway-lock}/bin/my-sway-lock";

            # Rofi
            "${modifier}+d" = "exec rofi -modes combi -show combi";
            "${modifier}+Shift+d" = "exec rofi -modes drun -show drun";
            "${modifier}+c" = "exec rofi -modes calc -show calc";
            "${modifier}+x" = "exec rofi -modes calc -show calc"; # TODO emoji

            # Screenshots
            "Print" = "exec ${pkgs.grimblast}/bin/grimblast --freeze --notify copy area";
            "Shift+Print" =
              "exec ${pkgs.grimblast}/bin/grimblast --freeze --notify copysave area /tmp/$(${pkgs.coreutils}/bin/date +'%H:%M:%S.png')";
            "${modifier}+p" = "exec ${pkgs.grimblast}/bin/grimblast --freeze --notify copy area";
            "${modifier}+Shift+p" =
              "exec ${pkgs.grimblast}/bin/grimblast --freeze --notify copysave area /tmp/$(${pkgs.coreutils}/bin/date +'%H:%M:%S.png')";

            # Brightness - logarithmic scale
            "XF86MonBrightnessDown" = "exec ${pkgs.light}/bin/light -T 0.618";
            "XF86MonBrightnessUp" = "exec ${pkgs.light}/bin/light -T 1.618";

            # Audio - logarithmic scale
            "XF86AudioRaiseVolume" = "exec '${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +1dB'";
            "XF86AudioLowerVolume" = "exec '${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -1dB'";
            "XF86AudioMute" = "exec '${pkgs.pamixer}/bin/pamixer -t'";
            "XF86AudioMicMute" = "exec ${pkgs.pamixer}/bin/pamixer --default-source -t";

            # Move to custom workspace
            "${modifier}+t" =
              "exec ${pkgs.sway}/bin/swaymsg workspace $(swaymsg -t get_workspaces | ${pkgs.jq}/bin/jq -r '.[].name' | rofi -dmenu -p 'Go to workspace:' )";
            "${modifier}+Shift+t" =
              "exec ${pkgs.sway}/bin/swaymsg move container to workspace $(swaymsg -t get_workspaces | ${pkgs.jq} -r '.[].name' | rofi -dmenu -p 'Move to workspace:')";
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

    services = {
      blueman-applet.enable = true;
      network-manager-applet.enable = true;

      gammastep = {
        enable = true;
        tray = true;
        latitude = 38.7;
        longitude = -9.14;
        temperature = {
          day = 6500;
          night = 2000;
        };
      };

      gnome-keyring = {
        enable = true;
        components = [ "secrets" ];
      };

      kanshi.systemdTarget = "sway-session.target";

      swayidle = {
        enable = true;
        events = [
          {
            event = "before-sleep";
            command = "${my-sway-lock}/bin/my-sway-lock";
          }
          {
            event = "lock";
            command = "${my-sway-lock}/bin/my-sway-lock";
          }
        ];
      };

      mako.enable = true;
    };
  };
}
