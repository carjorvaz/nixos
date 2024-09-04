{ ... }:

{
  networking = {
    networkmanager.enable = false;

    wireless = {
      enable = false;
      iwd.enable = false;
    };
  };

  powerManagement.powertop.enable = true;
  services.logind.lidSwitch = "ignore";

  services.tlp = {
    enable = true;
    settings = {
      START_CHARGE_THRESH_BAT0 = 40;
      STOP_CHARGE_THRESH_BAT0 = 60;
      START_CHARGE_THRESH_BAT1 = 40;
      STOP_CHARGE_THRESH_BAT1 = 60;
    };
  };
}
