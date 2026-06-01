{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Lightweight profile for temporary LLM-cluster worker boots. This is meant
  # for live-USB or disposable lab installs before promoting a machine to a
  # real host config.

  boot.kernelModules = [ "r8152" ];

  environment.systemPackages = [
    config.boot.kernelPackages.cpupower
    config.boot.kernelPackages.turbostat
    config.boot.kernelPackages.x86_energy_perf_policy
    pkgs.cpuid
    pkgs.curl
    pkgs.dmidecode
    pkgs.ethtool
    pkgs.hwloc
    pkgs.iperf3
    pkgs.jq
    pkgs.lm_sensors
    pkgs.msr-tools
    pkgs.numactl
    pkgs.pciutils
    pkgs.smartmontools
    pkgs.stress-ng
    pkgs.sysstat
    pkgs.usbutils
  ];

  networking.firewall = {
    allowedTCPPorts = [
      22
      5201
    ];
    allowedUDPPorts = [ 5201 ];
  };

  services = {
    openssh.enable = lib.mkDefault true;

    # ThinkPad lab mode: these machines are expected to sit plugged in while
    # preserving batteries for eventual resale.
    power-profiles-daemon.enable = lib.mkDefault false;
    tlp = {
      enable = lib.mkDefault true;
      settings = {
        START_CHARGE_THRESH_BAT0 = lib.mkDefault 40;
        STOP_CHARGE_THRESH_BAT0 = lib.mkDefault 60;
        START_CHARGE_THRESH_BAT1 = lib.mkDefault 40;
        STOP_CHARGE_THRESH_BAT1 = lib.mkDefault 60;

        CPU_ENERGY_PERF_POLICY_ON_AC = lib.mkDefault "performance";
        CPU_BOOST_ON_AC = lib.mkDefault 1;
        CPU_HWP_DYN_BOOST_ON_AC = lib.mkDefault 1;

        # Keep USB NICs boring during sustained fabric tests.
        USB_AUTOSUSPEND = lib.mkDefault 0;
        RUNTIME_PM_ON_AC = lib.mkDefault "on";
        WIFI_PWR_ON_AC = lib.mkDefault "off";
      };
    };
  };
}
