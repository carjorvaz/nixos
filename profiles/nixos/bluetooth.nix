{
  config,
  lib,
  pkgs,
  ...
}:

{
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  services.blueman.enable = lib.mkDefault true;
  home-manager.users.cjv.services.blueman-applet.enable = lib.mkDefault true;

  environment.persistence."/persist".directories = [ "/var/lib/bluetooth" ];
}
