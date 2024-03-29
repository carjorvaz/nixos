{ config, lib, pkgs, ... }:

{
  services.xserver.displayManager.startx.enable = true;

  environment.systemPackages = with pkgs; [ sbcl rlwrap yt-dlp mpv pulsemixer ];

  location = {
    latitude = 38.7;
    longitude = -9.14;
  };

  fonts = {
    enableDefaultFonts = true;
    fonts = with pkgs; [ iosevka-comfy.comfy ];
    fontconfig = { defaultFonts = { monospace = [ "Iosevka Comfy" ]; }; };
  };

  services = {
    redshift = {
      enable = true;
      temperature = {
        day = 6500;
        night = 2000;
      };
    };
  };

  home-manager.users.cjv = {
    home.file = {
      ".xinitrc".text = ''
        if test -z "$DBUS_SESSION_BUS_ADDRESS"; then
                 eval $(dbus-launch --exit-with-session --sh-syntax)
        fi

        systemctl --user import-environment DISPLAY XAUTHORITY
        systemctl --user start graphical-session.target

        if command -v dbus-update-activation-environment >/dev/null 2>&1; then
                dbus-update-activation-environment DISPLAY XAUTHORITY
        fi

        xrdb -merge ~/.Xresources
        exec ~/Documents/Code/stumpwm-source/stumpwm
      '';
    };

    xsession.enable = true;
    xresources.properties = {
      "xterm.termName" = "xterm-256color";
      "xterm*faceName" = "Monospace";
      "xterm*faceSize" = "14";
      "xterm*loginshell" = true;
      "xterm*metaSendsEscape" = true;
      "xterm*scrollBar" = true;
      "xterm*rightScrollBar" = true;
      "xterm*scrollTtyOutput" = false;
    };
  };
}
