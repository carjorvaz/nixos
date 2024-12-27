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
      # pkgs.cups-bjnp # Broken as of 2024/12/77 https://github.com/NixOS/nixpkgs/issues/368624
      pkgs.gutenprint
      pkgs.gutenprintBin
    ];
  };

  environment.persistence."/persist".directories = [ "/var/lib/cups" ];
}
