{
  pkgs,
  ...
}:

{
  imports = [ ./wayland.nix ];

  environment.systemPackages = with pkgs; [
    alacritty
    celluloid
    drawing
    foliate
    fragments
    ghostty
    gnome-sound-recorder
    gnome-tweaks
    inkscape
    metadata-cleaner
    pdfslicer
    ptyxis
    qalculate-gtk
    waypipe
    wl-clipboard
  ];

  services.xserver = {
    enable = true;
    desktopManager.gnome.enable = true;
    displayManager.gdm = {
      enable = true;
      autoSuspend = false;
    };
  };

  home-manager.users.cjv =
    { lib, ... }:
    {
      # Use `dconf watch /` to track stateful changes you are doing, then set them here.
      dconf.settings = {
        "org/gnome/desktop/input-sources" = {
          sources = [
            (lib.hm.gvariant.mkTuple [
              "xkb"
              "us+altgr-intl"
            ])
          ];
          xkb-options = [
            "lv3:ralt_switch"
            "ctrl:nocaps"
          ];
        };

        "org/gnome/desktop/interface" = {
          color-scheme = "prefer-light";
          show-battery-percentage = true;
        };

        "org/gnome/desktop/peripherals/mouse".accel-profile = "flat";

        "org/gnome/desktop/peripherals/touchpad" = {
          tap-to-click = true;
          two-finger-scrolling-enabled = true;
        };

        # "org/gnome/desktop/wm/preferences" = {
        #   focus-mode = "sloppy";
        # };

        "org/gnome/desktop/peripherals/keyboard" = {
          delay = lib.hm.gvariant.mkUint32 300;
          repeat-interval = lib.hm.gvariant.mkUint32 30;
        };

        "org/gnome/mutter" = {
          # Enable fractional scaling.
          experimental-features = [
            "scale-monitor-framebuffer"
            "xwayland-native-scaling"
          ];

          current-workspace-only = true;
          dynamic-workspaces = true;
          edge-tiling = true;
          workspaces-only-on-primary = true;
        };

        "org/gnome/settings-daemon/plugins/color" = {
          night-light-enabled = true;
          night-light-temperature = lib.hm.gvariant.mkUint32 1200;
          night-light-schedule-automatic = true;
        };

        "org/gnome/settings-daemon/plugins/power" = {
          sleep-inactive-ac-type = "nothing";
        };

        "org/gnome/eog/ui" = {
          image-gallery = true;
        };

        "org/gnome/shell" = {
          favorite-apps = [
            "brave-browser.desktop"
            "com.mitchellh.ghostty.desktop"
            "org.gnome.Nautilus.desktop"
            "emacs.desktop"
            "thunderbird.desktop"
            "discord.desktop"
            "Mattermost.desktop"
            "com.nextcloud.desktopclient.nextcloud.desktop"
          ];
        };

        "system/locale".region = "pt_PT.UTF-8";
      };

      gtk = lib.mkDefault {
        enable = true;

        theme = {
          # Use `dconf watch /` to see the correct name
          package = pkgs.adw-gtk3;
          name = "adw-gtk3";
        };

        iconTheme = {
          package = pkgs.adwaita-icon-theme;
          name = "Adwaita";
        };
      };

      programs.ghostty.settings = {
        adw-toolbar-style = "flat";
        window-theme = "ghostty";
      };
    };
}
