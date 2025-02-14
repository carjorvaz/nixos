{ pkgs, ... }:

# TODO:
# - plasma manager?
# - thunderbird?

# STATE:
# - disable saving clipboard history across sessions
# - night light; 2000k at night 38.7 -9.14
# - lower hot corner delay to 5 ms
# - speed up animations by 2 ticks
# - change keyboard repeat rate to 300/30
# - change wallpaper
# - change theme to breeze dark
# - pin to panel: brave, ghostty, dolphin, emacs, discord, mattermost, thunderbird
# - disable mouse acceleration
# - adjust display scaling
# - don't show media controls in lock screen

{
  imports = [ ./common.nix ];

  environment.sessionVariables = {
    # Make electron apps run on Wayland natively.
    NIXOS_OZONE_WL = "1";
  };

  services.xserver.displayManager.gdm.enable = false;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;
  services.desktopManager.plasma6.enable = true;

  environment.systemPackages = with pkgs; [
    ghostty

  ];

  # home-manager.users.cjv = {
  # };
}
