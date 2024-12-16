{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ./common.nix ];

  # Make electron apps run on Wayland natively.
  environment.sessionVariables = {
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
    NIXOS_OZONE_WL = "1";
    MOZ_ENABLE_WAYLAND = "1";
  };

  environment.systemPackages = with pkgs; [
    waypipe
    wdisplays
    wl-clipboard # wl-copy and wl-paste for copy/paste from stdin / stdout
    wl-mirror # contains wl-present
  ];

  programs.foot = {
    enable = true;
    settings = {
      main = {
        term = "xterm-256color";
        font = lib.mkDefault "monospace:size=13";
      };

      mouse.hide-when-typing = "yes";
    };
  };

  services.xserver.displayManager.lightdm.enable = false;
  services.xserver.displayManager.gdm = {
    enable = lib.mkDefault true;
    wayland = true;
  };

  home-manager.users.cjv = {
    # Solves small cursor on HiDPI.
    home.pointerCursor = {
      name = "Adwaita";
      package = pkgs.adwaita-icon-theme;
      size = 24;
      gtk.enable = true;
      x11.enable = true;
    };

    programs = {
      alacritty = {
        enable = true;
        settings = {
          font = {
            size = 13;
          };

          # env.TERM = "xterm-256color";
          # scrolling.multiplier = 5;
          # selection.save_to_clipboard = true;

          # Gruvbox Dark
          colors = {
            primary = {
              background = "0x282828";
              foreground = "0xebdbb2";
            };

            normal = {
              black = "0x282828";
              red = "0xcc241d";
              green = "0x98971a";
              yellow = "0xd79921";
              blue = "0x458588";
              magenta = "0xb16286";
              cyan = "0x689d6a";
              white = "0xa89984";
            };

            bright = {
              black = "0x928374";
              red = "0xfb4934";
              green = "0xb8bb26";
              yellow = "0xfabd2f";
              blue = "0x83a598";
              magenta = "0xd3869b";
              cyan = "0x8ec07c";
              white = "0xebdbb2";
            };
          };
        };
      };

      rofi = {
        enable = true;
        package = pkgs.rofi-wayland;
        cycle = true;
        terminal = "${pkgs.foot}/bin/foot";
        plugins = with pkgs; [
          # https://github.com/NixOS/nixpkgs/issues/298539
          (pkgs.rofi-calc.override { rofi-unwrapped = rofi-wayland-unwrapped; })
        ];
      };
    };

    services = {
      flameshot.enable = false;
      redshift.enable = false;

      dunst.enable = false;
      mako.enable = lib.mkDefault true;
    };
  };
}
