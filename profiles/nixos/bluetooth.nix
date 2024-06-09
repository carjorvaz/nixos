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

  services.blueman.enable = true;

  home-manager.users.cjv.services.blueman-applet.enable = true;

  environment.persistence."/persist".directories = [ "/var/lib/bluetooth" ];
}
