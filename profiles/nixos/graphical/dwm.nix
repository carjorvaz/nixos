{
  config,
  lib,
  pkgs,
  ...
}:

# TODO audio module in status bar with exponential scroll steps
{
  imports = [ ./common.nix ];

  services = {
    xserver.windowManager.dwm.enable = true;

    dwm-status = {
      enable = true;

      # TODO audio?
      order = lib.mkDefault [ "time" ];

      extraConfig = ''
        separator = " | "
      '';
    };
  };

  environment.systemPackages = with pkgs; [
    bemoji
    dmenu
    st
    stalonetray
  ];

  programs = {
    slock.enable = true;

    # To lock: loginctl lock-session
    # https://discourse.nixos.org/t/slock-when-suspend/22457
    xss-lock = {
      enable = true;
      lockerCommand = "/run/wrappers/bin/slock";
    };
  };
}
