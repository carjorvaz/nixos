{
  config,
  lib,
  pkgs,
  ...
}:

{
  # TODO faster "xrate"
  imports = [ ./common.nix ];

  environment.systemPackages = with pkgs; [
    celluloid
    drawing
    foliate
    fragments
    gnome-sound-recorder
    gnome-tweaks
    inkscape
    metadata-cleaner
    pdfslicer
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

        # Enable fractional scaling.
        "org/gnome/mutter" = {
          experimental-features = [ "scale-monitor-framebuffer" ];
        };

        "org/gnome/settings-daemon/plugins/color" = {
          night-light-enabled = true;
          night-light-temperature = lib.hm.gvariant.mkUint32 1700;
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
            "org.gnome.Console.desktop"
            "org.gnome.Nautilus.desktop"
            "emacs.desktop"
            "org.gnome.Geary.desktop"
            "Mattermost.desktop"
            "com.nextcloud.desktopclient.nextcloud.desktop"
          ];
        };
      };
    };
}
