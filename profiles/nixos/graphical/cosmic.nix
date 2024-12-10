{ pkgs, ... }:

{
  imports = [
    ./wayland.nix
  ];

  nix.settings = {
    substituters = [ "https://cosmic.cachix.org/" ];
    trusted-public-keys = [ "cosmic.cachix.org-1:Dya9IyXD4xdBehWjrkPv6rtxpmMdRel02smYzA85dPE=" ];
  };

  services.xserver.displayManager.gdm.enable = false;
  services.displayManager.cosmic-greeter.enable = true;

  # STATE:
  # - new workspace behaviour: tiling
  # - increase keyboard repeat rate
  # - disable mouse acceleration
  # - disable automatic suspend on desktops/plugged in
  # - change accent color to grey
  # - slightly round interface
  # - mouse follows focus, focus follows mouse
  # - disable dock
  # - top panel applets: remove workspace and applications; add workspace numbers
  # - scale X11 apps at native resolution
  # - time and date: 24 hours; week starts on monday
  # - touchpad:
  #   - disable while typing
  #   - secondary click with two fingers and middle click with three fingers
  #   - tap to click
  #   - scroll with two fingers
  #   - natural scrolling
  #   - decrease scroll speed (to 20)
  #   - terminal font size: 16px

  # Bindings (can't edit the default ones yet, need to add new ones):
  # - super does nothing
  # - open launcher: Super+D
  # - launch terminal: Super+Return
  # - close applications: Super+Shift+Q
  # - toggle floating: Super+Shift+Space (not working)
  services.desktopManager.cosmic.enable = true;

  environment.systemPackages = with pkgs; [
    # HACK: temporary workaround for night light
    sway
    gammastep
    foot

    grimblast
  ];

  services.blueman.enable = false;

  home-manager.users.cjv = {
    services = {
      blueman-applet.enable = false;
      mako.enable = false;
    };
  };
}
