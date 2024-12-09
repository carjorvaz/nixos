{ pkgs, ... }:

{
  imports = [
    #./wayland.nix
    ./common.nix
  ];

  nix.settings = {
    substituters = [ "https://cosmic.cachix.org/" ];
    trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
  };

  services.displayManager.cosmic-greeter.enable = true;
  services.desktopManager.cosmic.enable = true;

  environment.systemPackages = with pkgs; [
    sway
    gammastep
    foot

    waypipe
  ];

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
  };

  home-manager.users.cjv = {
    services = {
      flameshot.enable = false;
      redshift.enable = false;
      dunst.enable = false;
      mako.enable = false;
    };
  };
}
