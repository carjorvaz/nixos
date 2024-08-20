{
  config,
  lib,
  pkgs,
  ...
}:

{
  services.printing = {
    enable = true;
    drivers = [
      pkgs.cups-bjnp
      pkgs.gutenprint
      pkgs.gutenprintBin
    ];
  };

  environment.persistence."/persist".directories = [ "/var/lib/cups" ];
}
