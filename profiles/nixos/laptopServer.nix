{ lib, options, ... }:

let
  disableSleepSettings = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowSuspendThenHibernate = "no";
    AllowHybridSleep = "no";
  };
in

{
  powerManagement.powertop.enable = true;

  systemd.sleep =
    if options.systemd.sleep ? settings then
      {
        settings.Sleep = disableSleepSettings;
      }
    else
      {
        extraConfig = lib.generators.toKeyValue { } disableSleepSettings;
      };

  systemd.user.services.batsignal.enable = false;

  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
  };

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
