{ config, lib, pkgs, ... }:

{
  # CachyOS kernel - lowest input lag in my experience.
  # Alternatives:
  # boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  # boot.kernelPackages = pkgs.linuxPackages_zen;
  boot.kernelPackages = lib.mkDefault pkgs.cachyosKernels.linuxPackages-cachyos-latest-lto;
  boot.zfs.package = lib.mkDefault config.boot.kernelPackages.zfs_cachyos;

  # Prevent the AMD watchdog module from loading.
  boot.blacklistedKernelModules = [ "sp5100_tco" ];

  boot.kernelParams = [
    "mitigations=off"

    # Don't throttle processes that do misaligned atomic ops.
    "kernel.split_lock_mitigate=0"

    # Disable kernel lockup detectors (saves overhead, complements kernel.nmi_watchdog=0 sysctl).
    "nowatchdog"

    # Use TSC as reliable clocksource (fastest, avoids HPET/ACPI PM fallback overhead).
    "tsc=reliable"
  ];

  services.scx.enable = true;
  services.scx.scheduler = "scx_lavd";
  services.scx.extraArgs = [ "--autopower" ]; # Use hardware EPP signal for dynamic power mode

  # Automatic process priority management for desktop responsiveness.
  services.ananicy = {
    enable = true;
    package = pkgs.ananicy-cpp;
    rulesProvider = pkgs.ananicy-rules-cachyos;
  };

}
