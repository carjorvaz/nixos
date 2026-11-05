# Boot-time TU102 tensor-core unlock for the tiberius lane (see
# pkgs/turing-unlock for provenance, measured gains and licensing).
#
# This is opt-in and host-local: it builds the nlzy/turing-unlock kernel module
# against the plain nixpkgs kernel of the booted version and puts it, plus the
# six NVIDIA 610.43.03 firmware images it requests, into the initramfs so the
# module runs before nvidia can bind. The unlock is volatile (a power cycle
# restores the locked state) and no VBIOS or persistent GPU firmware is touched.
# Enable/disable takes effect on the next boot; a refused or failed unlock logs
# and the boot continues locked.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.turingUnlock;
  kernel = pkgs.linuxPackages.kernel;

  unlock = pkgs.callPackage ../../pkgs/turing-unlock { };
in
{
  options.hardware.turingUnlock = {
    enable = lib.mkEnableOption ''
      the TU102 full-rate tensor-core unlock at boot (volatile, no VBIOS flash)
    '';

    targets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "0000:17:00.0" ];
      description = ''
        PCI addresses of the cards to unlock (or `[ "all" ]`). The module only
        unlocks supported TU102/TU104/TU106 device IDs and skips a card that
        already has a driver bound, refuses unknown pre-write states, and does
        a PCIe FLR if the card needs one.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = kernel.modDirVersion == config.boot.kernelPackages.kernel.modDirVersion;
        message = ''
          hardware.turingUnlock: the module is built against nixpkgs kernel
          ${kernel.modDirVersion}, but this host boots
          ${config.boot.kernelPackages.kernel.modDirVersion}. The module's
          vermagic must match; adjust the kernel in
          pkgs/turing-unlock/default.nix.
        '';
      }
    ];

    hardware.firmware = [ unlock.firmware ];

    boot = {
      extraModulePackages = [ unlock.module ];

      # stage 1, before udev can load nvidia: the module expects the card in its
      # pre-driver state (nvidia on this host is not in the initramfs).
      initrd.kernelModules = [ "turing_unlock" ];
      initrd.extraFirmwarePaths = map (f: "turing-unlock/${unlock.nvVersion}/${f}") unlock.firmwareFiles;
      kernelParams = [ "turing_unlock.targets=${lib.concatStringsSep "," cfg.targets}" ];
    };
  };
}
