{ config, lib, pkgs, ... }:

{
  services.xserver.displayManager.startx.enable = true;

  environment.systemPackages = with pkgs; [ sbcl rlwrap ];

  home-manager.users.cjv = {
    services = {
      redshift = {
        enable = true;
        latitude = 38.7;
        longitude = -9.14;
        temperature = {
          day = 6500;
          night = 2000;
        };
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

        if command -v dbus-update-activation-environment >/dev/null 2>&1; then
                dbus-update-activation-environment DISPLAY XAUTHORITY
        fi

        exec ~/Documents/Code/stumpwm-source/stumpwm
      '';
    };

  };
}
