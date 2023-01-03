{ config, lib, pkgs, ... }:

{
  powerManagement.powertop.enable = true;
  services = {
    power-profiles-daemon.enable = true;
    udev.extraRules = ''
      SUBSYSTEM=="power_supply",ENV{POWER_SUPPLY_ONLINE}=="0",RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set power-saver"
      SUBSYSTEM=="power_supply",ENV{POWER_SUPPLY_ONLINE}=="1",RUN+="${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced"
    '';
  };

  environment.systemPackages = with pkgs; [ powertop ];
}
