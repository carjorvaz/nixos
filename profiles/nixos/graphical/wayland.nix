{ config, lib, pkgs, ... }:

{
  imports = [ ./common.nix ];
  # Make electron apps run on Wayland natively.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  environment.systemPackages = with pkgs; [
    wdisplays
    wl-clipboard # wl-copy and wl-paste for copy/paste from stdin / stdout
    wl-mirror # contains wl-present
  ];

  services.xserver.displayManager.gdm = {
    enable = true;
    wayland = true;
  };

  home-manager.users.cjv = {
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
        plugins = with pkgs;
          [
            # https://github.com/NixOS/nixpkgs/issues/298539
            (pkgs.rofi-calc.override {
              rofi-unwrapped = rofi-wayland-unwrapped;
            })
          ];
      };

      swaylock = {
        enable = true;
        settings = {
          color = lib.mkDefault "000000";
          font-size = 14;
          # Needed for fingerprint to work with swaylock.
          # Press enter than tap finger.
          ignore-empty-password = false;
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
