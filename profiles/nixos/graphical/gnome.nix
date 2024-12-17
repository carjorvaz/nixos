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
    gnome-sound-recorder
    gnome-tweaks
    inkscape
    metadata-cleaner
    pdfslicer
    ptyxis
    qalculate-gtk
    waypipe
    wl-clipboard

    gnomeExtensions.appindicator
    gnomeExtensions.just-perfection
    gnomeExtensions.blur-my-shell
    gnomeExtensions.space-bar
    gnomeExtensions.undecorate
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
          hash = "sha256-JaqJvbuIAFDKJ3y/8j/7hZ+/Eqru+Mm1d3EvjfmCcug=";
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

  services.blueman.enable = false;

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
        };

        "org/gnome/desktop/peripherals/mouse".accel-profile = "flat";

        "org/gnome/desktop/peripherals/touchpad" = {
          tap-to-click = true;
          two-finger-scrolling-enabled = true;
        };

        "org/gnome/desktop/wm/preferences" = {
          focus-mode = "mouse";
          num-workspaces = 9;
        };

        "org/gnome/shell/keybindings" = lib.pipe (lib.range 1 9) [
          (lib.map toString)
          (lib.map (i: [
            (lib.nameValuePair "switch-to-application-${i}" (
              lib.hm.gvariant.mkEmptyArray lib.hm.gvariant.type.string
            ))
          ]))
          lib.flatten
          builtins.listToAttrs
        ];

        "org/gnome/desktop/peripherals/keyboard" = {
          delay = lib.hm.gvariant.mkUint32 300;
          repeat-interval = lib.hm.gvariant.mkUint32 30;
        };

        "org/gnome/desktop/wm/keybindings" =
          lib.pipe (lib.range 1 9) [
            (lib.map toString)
            (lib.map (i: [
              (lib.nameValuePair "switch-to-workspace-${i}" [ "<Super>${i}" ])
              (lib.nameValuePair "move-to-workspace-${i}" [ "<Shift><Super>${i}" ])
            ]))
            lib.flatten
            builtins.listToAttrs
          ]
          // {
            close = [ "<Shift><Super>q" ];
          };

        "org/gnome/mutter" = {
          # Enable fractional scaling.
          experimental-features = [ "scale-monitor-framebuffer" ];

          center-new-windows = true;
          current-workspace-only = true;
          dynamic-workspaces = false;
          workspaces-only-on-primary = true;
        };

        "org/gnome/settings-daemon/plugins/color" = {
          night-light-enabled = true;
          night-light-temperature = lib.hm.gvariant.mkUint32 1200;
          night-light-schedule-automatic = true;
        };

        "org/gnome/settings-daemon/plugins/media-keys" = {
          screensaver = [ "<Super>o" ];
        };

        # STATE: Needs to be created manually
        "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
          binding = "<Super>Return";
          command = "alacritty";
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
            "Alacritty.desktop"
            "org.gnome.Nautilus.desktop"
            "emacs.desktop"
            "thunderbird.desktop"
            "Mattermost.desktop"
            "com.nextcloud.desktopclient.nextcloud.desktop"
          ];

          # https://wiki.nixos.org/wiki/GNOME#Managing_extensions
          disable-user-extensions = false; # enables user extensions
          enabled-extensions = [
            pkgs.gnomeExtensions.appindicator.extensionUuid
            pkgs.gnomeExtensions.just-perfection.extensionUuid
            pkgs.gnomeExtensions.blur-my-shell.extensionUuid
            pkgs.gnomeExtensions.space-bar.extensionUuid
            pkgs.gnomeExtensions.undecorate.extensionUuid
          ];
        };

        # Configure Just Perfection
        "org/gnome/shell/extensions/just-perfection" = {
          animation = 2;
          dash-app-running = true;
          workspace = true;
          workspace-popup = false;
        };

        # Configure Blur My Shell
        "org/gnome/shell/extensions/blur-my-shell/appfolder".blur = false;
        "org/gnome/shell/extensions/blur-my-shell/lockscreen".blur = false;
        "org/gnome/shell/extensions/blur-my-shell/screenshot".blur = false;
        "org/gnome/shell/extensions/blur-my-shell/window-list".blur = false;
        "org/gnome/shell/extensions/blur-my-shell/panel".blur = false;
        "org/gnome/shell/extensions/blur-my-shell/overview".blur = true;
        "org/gnome/shell/extensions/blur-my-shell/overview".pipeline = "pipeline_default";
        "org/gnome/shell/extensions/blur-my-shell/dash-to-dock".blur = true;
        "org/gnome/shell/extensions/blur-my-shell/dash-to-dock".brightness = "0/6";
        "org/gnome/shell/extensions/blur-my-shell/dash-to-dock".sigma = 30;
        "org/gnome/shell/extensions/blur-my-shell/dash-to-dock".static-blur = true;
        "org/gnome/shell/extensions/blur-my-shell/dash-to-dock".style-dash-to-dock = 0;

        # Configure Space Bar
        "org/gnome/shell/extensions/space-bar/behavior".smart-workspace-names = false;
        "org/gnome/shell/extensions/space-bar/shortcuts".enable-activate-workspace-shortcuts = false;
        "org/gnome/shell/extensions/space-bar/shortcuts".enable-move-to-workspace-shortcuts = true;
        "org/gnome/shell/extensions/space-bar/shortcuts".open-menu =
          lib.hm.gvariant.mkEmptyArray lib.hm.gvariant.type.string;
      };

      services = {
        blueman-applet.enable = false;
        mako.enable = false;
      };
    };
}
