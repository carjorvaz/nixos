{ config, lib, pkgs, ... }:

{
  # Make electron apps run on Wayland natively.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  environment.systemPackages = with pkgs; [
    bashmount
    glib # gsettings
    libqalculate
    pulseaudio # for pactl
    pulsemixer
    wdisplays
    wl-clipboard # wl-copy and wl-paste for copy/paste from stdin / stdout
    wl-mirror # contains wl-present

    gnome.nautilus
    gnome.seahorse
    imv
    mpv
  ];

  fonts = {
    fontDir.enable = true;
    fontconfig.defaultFonts.monospace = [ "JetBrainsMono Nerd Font" ];
    packages = with pkgs;
      [ (nerdfonts.override { fonts = [ "JetBrainsMono" ]; }) ];
  };

  programs.light.enable = true;
  users.users.cjv.extraGroups = [ "video" ]; # For rootless light.

  services = {
    gnome.gnome-keyring.enable = true;

    pipewire = {
      enable = true;
      alsa.enable = true;
      pulse.enable = true;
    };

    xserver.displayManager.gdm = {
      enable = true;
      wayland = true;
      autoSuspend = false;
    };
  };

  home-manager.users.cjv = {
    gtk = {
      enable = true;
      theme = {
        # Use `dconf watch /` to see the correct name
        package = lib.mkDefault pkgs.adw-gtk3;
        name = lib.mkDefault "adw-gtk3-dark";
      };

      iconTheme = {
        package = lib.mkDefault pkgs.gnome.adwaita-icon-theme;
        name = lib.mkDefault "Adwaita";
      };
    };

    qt = {
      enable = true;
      platformTheme = lib.mkDefault "gnome";
      style = {
        name = lib.mkDefault "adwaita-dark";
        package = lib.mkDefault pkgs.adwaita-qt;
      };
    };

    # Solves small cursor on HiDPI.
    home.pointerCursor = {
      name = "Adwaita";
      package = pkgs.gnome.adwaita-icon-theme;
      size = 24;
      gtk.enable = true;
      x11.enable = true;
    };

    programs = {
      foot = {
        enable = true;
        settings = {
          main = {
            term = "xterm-256color";
            font = lib.mkDefault "monospace:size=12";
          };

          mouse.hide-when-typing = "yes";
        };
      };

      rofi = {
        enable = true;
        package = pkgs.rofi-wayland;
        cycle = true;
        terminal = "${pkgs.foot}/bin/foot";
        plugins = with pkgs; [ rofi-calc ];
      };

      swaylock = {
        enable = true;
        settings = {
          color = lib.mkDefault "000000";
          font-size = 14;
          ignore-empty-password = true;
          show-failed-attempts = true;
        };
      };
    };

    services = {
      gammastep = {
        enable = true;
        tray = true;
        latitude = 38.7;
        longitude = -9.14;
        temperature = {
          day = 6500;
          night = 2000;
        };
      };

      mako.enable = true;

      swayidle = {
        enable = true;
        events = [
          {
            event = "before-sleep";
            command = "${pkgs.swaylock}/bin/swaylock";
          }
          {
            event = "lock";
            command = "${pkgs.swaylock}/bin/swaylock";
          }
        ];
      };
    };
  };
}
