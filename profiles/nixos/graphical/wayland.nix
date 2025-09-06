{ lib, pkgs, ... }:

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

        pad = "5x5";
      };

      mouse.hide-when-typing = "yes";
    };

    theme = lib.mkDefault "gruvbox-dark";
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
    };
  };
}
