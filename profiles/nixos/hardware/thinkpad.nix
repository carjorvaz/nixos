{
  config,
  lib,
  pkgs,
  ...
}:

{
  boot = {
    # For battery thresholds.
    kernelModules = [ "acpi_call" ];
    extraModulePackages = with config.boot.kernelPackages; [ acpi_call ];
  };

  services.tlp.settings = {
    # Extend battery longevity.
    START_CHARGE_THRESH_BAT0 = 75;
    STOP_CHARGE_THRESH_BAT0 = 80;
  };
}
