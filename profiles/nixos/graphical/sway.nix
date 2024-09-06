{
  config,
  inputs,
  pkgs,
  lib,
  ...
}:

let
  # bash script to let dbus know about important env variables and
  # propogate them to relevent services run at the end of sway config
  # see
  # https://github.com/emersion/xdg-desktop-portal-wlr/wiki/"It-doesn't-work"-Troubleshooting-Checklist
  # note: this is pretty much the same as  /etc/sway/config.d/nixos.conf but also restarts
  # some user services to make sure they have the correct environment variables
  dbus-sway-environment = pkgs.writeTextFile {
    name = "dbus-sway-environment";
    destination = "/bin/dbus-sway-environment";
    executable = true;

    text = ''
      dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=sway
      systemctl --user stop pipewire pipewire-media-session xdg-desktop-portal xdg-desktop-portal-wlr
      systemctl --user start pipewire pipewire-media-session xdg-desktop-portal xdg-desktop-portal-wlr
    '';
  };

  # currently, there is some friction between sway and gtk:
  # https://github.com/swaywm/sway/wiki/GTK-3-settings-on-Wayland
  # the suggested way to set gtk settings is with gsettings
  # for gsettings to work, we need to tell it where the schemas are
  # using the XDG_DATA_DIR environment variable
  # run at the end of sway config
  configure-gtk = pkgs.writeTextFile {
    name = "configure-gtk";
    destination = "/bin/configure-gtk";
    executable = true;
    text =
      let
        schema = pkgs.gsettings-desktop-schemas;
        datadir = "${schema}/share/gsettings-schemas/${schema.name}";
      in
      ''
        export XDG_DATA_DIRS=${datadir}:$XDG_DATA_DIRS
        gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' && gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
      '';
  };
in
{
  imports = [ ./wayland.nix ];

  environment.systemPackages = with pkgs; [
    sway
    dbus-sway-environment
    configure-gtk
    wayland

    swaylock
    swayidle

    # screenshot functionality
    grim
    slurp
    sway-contrib.grimshot
  ];

  services.dbus.enable = true;
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
  };

  security.polkit.enable = true;

  networking.networkmanager.enable = false; # Use only iwd and dhcpcd.

  systemd.user.services = {
    nextcloud-client.wantedBy = lib.mkForce [ "sway-session.target" ];
  };

  home-manager.users.cjv = {
    programs = {
      i3status-rust.enable = true;

      swaylock = {
        enable = true;
        settings = {
          color = lib.mkDefault "000000";
          font-size = 14;
          # Needed for fingerprint to work with swaylock.
          # Press enter than tap finger.
          ignore-empty-password = false;
          show-failed-attempts = true;
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

          # TODO default acceleration for touchpads
          "type:touchpad" = {
            tap = "enabled";
            natural_scroll = "enabled";
          };
        };

        output = {
          "*".bg = lib.mkDefault "${./wallpaper.jpg} fill";

          "eDP-1".scale = "1.25";
        };

        keybindings =
          let
            modifier = config.home-manager.users.cjv.wayland.windowManager.sway.config.modifier;
          in
          lib.mkOptionDefault {
            "${modifier}+Escape" = "exec ${pkgs.swaylock}/bin/swaylock";

            # Rofi
            "${modifier}+d" = "exec rofi -modes combi -show combi";
            "${modifier}+Shift+d" = "exec rofi -modes drun -show drun";
            "${modifier}+c" = "exec rofi -modes calc -show calc";
            "${modifier}+x" = "exec rofi -modes calc -show calc"; # TODO emoji

            # Screenshots
            "Print" = "exec ${pkgs.sway-contrib.grimshot}/bin/grimshot --notify copy area";
            "Shift+Print" = "exec ${pkgs.sway-contrib.grimshot}/bin/grimshot --notify save area /tmp/$(${pkgs.coreutils}/bin/date +'%H:%M:%S.png')";
            "${modifier}+p" = "exec ${pkgs.sway-contrib.grimshot}/bin/grimshot --notify copy area";
            "${modifier}+Shift+p" = "exec ${pkgs.sway-contrib.grimshot}/bin/grimshot --notify save area /tmp/$(${pkgs.coreutils}/bin/date +'%H:%M:%S.png')";

            # Brightness - logarithmic scale
            "XF86MonBrightnessDown" = "exec ${pkgs.light}/bin/light -T 0.618";
            "XF86MonBrightnessUp" = "exec ${pkgs.light}/bin/light -T 1.618";

            # Audio - logarithmic scale
            "XF86AudioRaiseVolume" = "exec '${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ +2dB'";
            "XF86AudioLowerVolume" = "exec '${pkgs.pulseaudio}/bin/pactl set-sink-volume @DEFAULT_SINK@ -2dB'";
            "XF86AudioMute" = "exec '${pkgs.pamixer}/bin/pamixer -t'";
            "XF86AudioMicMute" = "exec ${pkgs.pamixer}/bin/pamixer --default-source -t";

            # Move to custom workspace
            "${modifier}+t" = "exec ${pkgs.sway}/bin/swaymsg workspace $(swaymsg -t get_workspaces | ${pkgs.jq}/bin/jq -r '.[].name' | rofi -dmenu -p 'Go to workspace:' )";
            "${modifier}+Shift+t" = "exec ${pkgs.sway}/bin/swaymsg move container to workspace $(swaymsg -t get_workspaces | ${pkgs.jq} -r '.[].name' | rofi -dmenu -p 'Move to workspace:')";
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

      extraConfig = ''
        exec ${dbus-sway-environment}/bin/dbus-sway-environment
        exec ${configure-gtk}/bin/configure-gtk
      '';

      extraSessionCommands = ''
        # Needed for GNOME Keyring's SSH integration.
        eval $(/run/wrappers/bin/gnome-keyring-daemon --start --components=ssh)
        export SSH_AUTH_SOCK
      '';
    };

    services = {
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

      kanshi.systemdTarget = "sway-session.target";

      swayidle = {
        enable = true;
        events = [
          {
            event = "before-sleep";
            command = "${pkgs.swaylock}/bin/swaylock";
          }
          {
            event = "lock";
            command = "${pkgs.swaylock}/bin/swaylock";
          }
        ];

        timeouts = [
          {
            timeout = 2;
            command = ''if ${pkgs.procps}/bin/pgrep swaylock; then ${pkgs.sway}/bin/swaymsg "output * dpms off"; fi'';
            resumeCommand = ''${pkgs.sway}/bin/swaymsg "output * dpms on"'';
          }
        ];
      };
    };
  };
}
