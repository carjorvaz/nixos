{ config, lib, pkgs, ... }:

{
  services.printing = {
    enable = true;
    drivers = [
      pkgs.canon-cups-ufr2
      pkgs.cups-bjnp
      pkgs.gutenprint
      pkgs.gutenprintBin
    ];
  };
}
