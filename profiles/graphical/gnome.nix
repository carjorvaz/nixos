{ config, lib, pkgs, ... }:

{
  services.xserver = {
    enable = true;
    desktopManager.gnome.enable = true;
    displayManager.gdm = {
      enable = true;
      wayland = true;
      autoSuspend = false;
    };
  };

  programs.dconf.enable = true;

  home-manager.users.cjv = {
    # Use `dconf watch /` to track stateful changes you are doing, then set them here.
    dconf.settings = {
      "org/gnome/desktop/interface" = {
        color-scheme = "prefer-dark";
        gtk-theme = "Adwaita-dark";
      };

      "/org/gnome/desktop/peripherals/mouse" = { accel-profile = "flat"; };

      "org/gnome/shell" = {
        favorite-apps = [
          "brave-browser.desktop"
          "org.gnome.Console.desktop"
          "org.gnome.Nautilus.desktop"
          "emacs.desktop"
          "discord.desktop"
          "com.github.flxzt.rnote.desktop"
          "org.gnome.Geary.desktop"
          "Mattermost.desktop"
          "com.nextcloud.desktopclient.nextcloud.desktop"
        ];
      };
    };
  };
}
