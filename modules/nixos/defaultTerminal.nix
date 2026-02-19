{ lib, ... }:

{
  options.graphical.defaultTerminal = lib.mkOption {
    type = lib.types.str;
    default = "foot";
    description = "Default terminal emulator for graphical environments";
  };
}
