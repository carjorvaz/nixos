{ config, inputs, pkgs, lib, ... }:

# TODO:
# - fn + f7 wdisplays
# - kanshi
# - image viewer (https://github.com/artemsen/swayimg)
# - calendar
# - email

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
    text = let
      schema = pkgs.gsettings-desktop-schemas;
      datadir = "${schema}/share/gsettings-schemas/${schema.name}";
    in ''
      export XDG_DATA_DIRS=${datadir}:$XDG_DATA_DIRS
      gsettings set org.gnome.desktop.interface gtk-theme 'adw-gtk3-dark' && gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    '';
  };

  lockCommand = "${pkgs.swaylock}/bin/swaylock -e -f";
in {
  environment.systemPackages = with pkgs; [
    foot
    sway
    dbus-sway-environment
    configure-gtk
    wayland
    glib # gsettings
    gnome3.adwaita-icon-theme # default gnome cursors
    adw-gtk3 # gtk-theme

    swaylock
    swayidle

    # screenshot functionality
    grim
    slurp
    sway-contrib.grimshot

    wl-clipboard # wl-copy and wl-paste for copy/paste from stdin / stdout
    bemenu # wayland clone of dmenu
    mako # notification system developed by swaywm maintainer
    pulseaudio # for pactl
    pulsemixer
    bashmount
    wdisplays
    wl-mirror
    squeekboard # on-screen keyboard

    mattermost-desktop
    gnome.nautilus
    mpv
    imv
    libqalculate
    gnome.seahorse
  ];

  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
  };

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

    light.enable = true;
    dconf.enable = true;
  };

  users.users.cjv.extraGroups = [ "video" ]; # For rootless light.

  services.xserver.displayManager.gdm = {
    enable = true;
    wayland = true;
    autoSuspend = false;
  };

  security.polkit.enable = true;

  environment.sessionVariables = { NIXOS_OZONE_WL = "1"; };

  fonts = {
    enableDefaultFonts = true;
    fontDir.enable = true;
    fonts = with pkgs; [ (nerdfonts.override { fonts = [ "FiraCode" ]; }) ];
    fontconfig = { defaultFonts = { monospace = [ "FiraCode Nerd Font" ]; }; };
  };

  networking.networkmanager.enable = false; # Use only iwd and dhcpcd.

  services.gnome.gnome-keyring.enable = true;

  systemd.user.services = {
    nextcloud-client.wantedBy = lib.mkForce [ "sway-session.target" ];
  };

  home-manager.users.cjv = {
    # Solves small cursor on HiDPI.
    home.pointerCursor = {
      name = "Adwaita";
      package = pkgs.gnome.adwaita-icon-theme;
      size = 24;
      x11 = {
        enable = true;
        defaultCursor = "Adwaita";
      };
    };

    programs = {
      swaylock.settings = {
        color = "000000";
        show-failed-attempts = true;
      };

      foot = {
        enable = true;
        settings = {
          main = {
            term = "xterm-256color";
            font = "monospace:size=14";
            dpi-aware = "yes";
          };

          mouse.hide-when-typing = "yes";
        };
      };

      i3status-rust = {
        enable = true;
        bars.top = {
          icons = "awesome";
          theme = "plain";
        };
      };
    };

    wayland.windowManager.sway = {
      enable = true;
      systemdIntegration = true;
      wrapperFeatures = {
        base = true;
        gtk = true;
      };

      config = rec {
        modifier = "Mod4";
        terminal = "foot";
        menu =
          "bemenu-run -i -n -p '' --fn 'monospace 11' -H 23 --tb '#1a1a1a' --tf '#268bd2' --fb '#1a1a1a' --nb '#1a1a1a' --hb '#1a1a1a' --hf '#268bd2'";

        input = {
          "type:keyboard" = {
            xkb_layout = "us";
            xkb_options = "ctrl:nocaps,compose:prsc";
            xkb_variant = "altgr-intl";
          };

          "type:touchpad" = {
            tap = "enabled";
            natural_scroll = "enabled";
          };
        };

        keybindings = let
          modifier =
            config.home-manager.users.cjv.wayland.windowManager.sway.config.modifier;
        in lib.mkOptionDefault {
          "${modifier}+Escape" = "exec ${lockCommand}";

          # Screenshots
          "Insert" =
            "exec ${pkgs.sway-contrib.grimshot}/bin/grimshot --notify copy area";
          "Shift+Insert" =
            "exec ${pkgs.sway-contrib.grimshot}/bin/grimshot --notify save area /tmp/$(${pkgs.coreutils}/bin/date +'%H:%M:%S.png')";

          # Brightness
          "XF86MonBrightnessDown" = "exec ${pkgs.light}/bin/light -T 0.72";
          "XF86MonBrightnessUp" = "exec ${pkgs.light}/bin/light -T 1.4";

          "XF86AudioRaiseVolume" =
            "exec '${pkgs.pamixer}/bin/pamixer --increase 5'";
          "XF86AudioLowerVolume" =
            "exec '${pkgs.pamixer}/bin/pamixer --decrease 5'";
          "XF86AudioMute" = "exec '${pkgs.pamixer}/bin/pamixer -t'";
          "XF86AudioMicMute" =
            "exec ${pkgs.pamixer}/bin/pamixer --default-source -t";

          # Move to custom workspace
          "${modifier}+t" =
            "exec ${pkgs.sway}/bin/swaymsg workspace $(swaymsg -t get_workspaces | ${pkgs.jq}/bin/jq -r '.[].name' | ${pkgs.bemenu}/bin/bemenu -p 'Go to workspace:' )";
          "${modifier}+Shift+t" =
            "exec ${pkgs.sway}/bin/swaymsg move container to workspace $(swaymsg -t get_workspaces | ${pkgs.jq} -r '.[].name' | ${pkgs.bemenu}/bin/bemenu -p 'Move to workspace:')";
        };

        bars = [{
          statusCommand =
            "${pkgs.i3status-rust}/bin/i3status-rs ~/.config/i3status-rust/config-top.toml";
          position = "top";
          fonts = {
            size = 12.0;
            names = [ "monospace" ];
          };
        }];
      };

      extraConfig = ''
        exec dbus-sway-environment
        exec configure-gtk
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
        latitude = 38.7;
        longitude = -9.14;
        temperature = {
          day = 6500;
          night = 2000;
        };
      };

      swayidle = {
        enable = true;
        events = [
          {
            event = "before-sleep";
            command = lockCommand;
          }
          {
            event = "lock";
            command = lockCommand;
          }
        ];

        timeouts = [
          {
            timeout = 300;
            command = lockCommand;
          }
          {
            timeout = 2;
            command = ''
              if ${pkgs.procps}/bin/pgrep swaylock; then ${pkgs.sway}/bin/swaymsg "output * dpms off"; fi'';
            resumeCommand = ''${pkgs.sway}/bin/swaymsg "output * dpms on"'';
          }
        ];
      };
    };
  };
}
