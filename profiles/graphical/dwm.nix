{ config, lib, pkgs, ... }:

{
  # TODO auto lock e super + escape a dar lock (passa dois segundos e desligar ecra)
  # TODO usar alt em vez de super com o dwm e deixar de ter super, tenho mais liberdade para por igual ao mac com ctrl no alt e alt no super
  # TODO wallpaper
  # TODO wide extend layer (migrar para kanata)

  environment.systemPackages = with pkgs; [ dmenu ];

  fonts = {
    enableDefaultFonts = true;
    fontDir.enable = true;
    fonts = with pkgs; [ (nerdfonts.override { fonts = [ "FiraCode" ]; }) ];
    fontconfig = { defaultFonts = { monospace = [ "FiraCode Nerd Font" ]; }; };
  };

  location = {
    latitude = 38.7;
    longitude = -9.14;
  };

  programs.slock.enable = true;

  services = {
    dwm-status = {
      enable = true;
      order = [ "audio" "time" ];
    };

    redshift = {
      enable = true;
      temperature = {
        day = 6500;
        night = 2000;
      };
    };

    xserver.windowManager.dwm.enable = true;
  };

  home-manager.users.cjv = {
    services = {
      dunst.enable = true;
      flameshot.enable = true;
    };

    xsession = {
      enable = true;
      profileExtra = ''
        # Needed for GNOME Keyring's SSH integration.
        eval $(/run/wrappers/bin/gnome-keyring-daemon --start --components=ssh)
        export SSH_AUTH_SOCK
      '';
    };

    xresources.properties = {
      "xterm.termName" = "xterm-256color";
      "xterm*faceName" = "Monospace";
      "xterm*faceSize" = "14";
      "xterm*loginshell" = true;
      "xterm*metaSendsEscape" = true;
      "xterm*scrollBar" = true;
      "xterm*rightScrollBar" = true;
      "xterm*scrollTtyOutput" = false;
      "xterm*background" = "black";
      "xterm*foreground" = "white";
    };
  };
}
