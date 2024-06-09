{
  config,
  lib,
  pkgs,
  ...
}:

{
  boot.kernelModules = [ "kvm-amd" ];
  hardware.cpu.amd.updateMicrocode = true;
}
