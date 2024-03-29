{ config, lib, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    blackbox-terminal
    celluloid
    drawing
    foliate
    fragments
    gnome.gnome-sound-recorder
    gnome.gnome-terminal
    gnome.gnome-tweaks
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
      wayland = true;
      autoSuspend = false;
    };
  };

  # https://github.com/NixOS/nixpkgs/issues/103746
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;

  programs.dconf.enable = true;

  home-manager.users.cjv = { lib, ... }: {
    # Use `dconf watch /` to track stateful changes you are doing, then set them here.
    dconf.settings = {
      "org/gnome/desktop/input-sources" = {
        sources = [ (lib.hm.gvariant.mkTuple [ "xkb" "us+altgr-intl" ]) ];
        xkb-options = [ "lv3:ralt_switch" "ctrl:nocaps" ];
      };

      "org/gnome/desktop/interface" = {
        color-scheme = "prefer-dark";
        gtk-theme = "Adwaita-dark";
      };

      "org/gnome/desktop/peripherals/mouse".accel-profile = "flat";

      "org/gnome/desktop/peripherals/touchpad" = {
        tap-to-click = true;
        two-finger-scrolling-enabled = true;
      };

      "org/gnome/settings-daemon/plugins/color" = {
        night-light-enabled = true;
        night-light-temperature = lib.hm.gvariant.mkUint32 1700;
        night-light-schedule-automatic = true;
      };

      "org/gnome/settings-daemon/plugins/power" = {
        sleep-inactive-ac-type = "nothing";
      };

      "org/gnome/eog/ui" = { image-gallery = true; };

      "org/gnome/shell" = {
        favorite-apps = [
          "brave-browser.desktop"
          "org.gnome.Console.desktop"
          "org.gnome.Nautilus.desktop"
          "emacs.desktop"
          "discord.desktop"
          "org.gnome.Geary.desktop"
          "Mattermost.desktop"
          "com.nextcloud.desktopclient.nextcloud.desktop"
        ];
      };
    };
  };
}
