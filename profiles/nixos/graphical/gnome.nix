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

  # https://wiki.nixos.org/wiki/GNOME#Systray_Icons
  services.udev.packages = [ pkgs.gnome-settings-daemon ];

  services.xserver = {
    enable = true;
    desktopManager.gnome.enable = true;
    displayManager.gdm = {
      enable = true;
      autoSuspend = false;
    };
  };

  # https://discourse.nixos.org/t/overlays-seem-ignored-when-sudo-nixos-rebuild-switch-gnome-47-triple-buffering-compilation-errors/55434/12
  nixpkgs.overlays = [
    (final: prev: {
      mutter = prev.mutter.overrideAttrs (oldAttrs: {
        # GNOME dynamic triple buffering (huge performance improvement)
        # See https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/1441
        src = final.fetchFromGitLab {
          domain = "gitlab.gnome.org";
          owner = "vanvugt";
          repo = "mutter";
          rev = "triple-buffering-v4-47";
          hash = "sha256-ajxm+EDgLYeqPBPCrgmwP+FxXab1D7y8WKDQdR95wLI=";
        };

        preConfigure =
          let
            gvdb = final.fetchFromGitLab {
              domain = "gitlab.gnome.org";
              owner = "GNOME";
              repo = "gvdb";
              rev = "2b42fc75f09dbe1cd1057580b5782b08f2dcb400";
              hash = "sha256-CIdEwRbtxWCwgTb5HYHrixXi+G+qeE1APRaUeka3NWk=";
            };
          in
          ''
            cp -a "${gvdb}" ./subprojects/gvdb
          '';
      });
    })
  ];

  environment.sessionVariables = {
    # Make electron apps run on Wayland natively.
    NIXOS_OZONE_WL = "1";
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
          color-scheme = "prefer-dark";
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
            "org.gnome.Geary.desktop"
            "discord.desktop"
            "Mattermost.desktop"
            "com.nextcloud.desktopclient.nextcloud.desktop"
          ];
        };

        "system/locale".region = "pt_PT.UTF-8";
      };

      programs.ghostty = {
        enable = true;
        settings = {
          font-size = 14;

          adw-toolbar-style = "flat";
          theme = "GruvboxDark";
          window-theme = "ghostty";
          # window-decoration = false; # Enable for window managers
        };
      };
    };
}
