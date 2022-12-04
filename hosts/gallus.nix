{ config, pkgs, lib, suites, ... }:

{
  imports = suites.gallus;

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "nvme" "usb_storage" "sd_mod" ];
  boot.kernelModules = [ "kvm-intel" "acpi_call"];
  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  boot.extraModulePackages = with config.boot.kernelPackages; [ acpi_call ];

  boot.supportedFilesystems = [ "zfs" ];
  networking.hostId = "b60d3eae";

  fileSystems."/" = {
    device = "zroot/local/root";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/23BD-94D0";
    fsType = "vfat";
  };

  fileSystems."/nix" = {
    device = "zroot/local/nix";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/home" = {
    device = "zroot/safe/home";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/persist" = {
    device = "zroot/safe/persist";
    fsType = "zfs";
    options = [ "zfsutil" ];
    neededForBoot = true;
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    sensor.iio.enable = true;
  };

  networking.useDHCP = lib.mkDefault true;
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  hardware.video.hidpi.enable = lib.mkDefault true;

  boot.initrd.kernelModules = [ "i915" ];
  environment.variables.VDPAU_DRIVER = "va_gl";
  hardware.opengl = {
    enable = true;
    extraPackages = with pkgs; [ vaapiIntel libvdpau-va-gl intel-media-driver ];
  };

  services = {
    throttled.enable = true;
    xserver.wacom.enable = true;
    udev.extraRules = ''
      # blacklist Lenovo IR camera
      SUBSYSTEM=="usb", ATTRS{idVendor}=="5986", ATTRS{idProduct}=="211a", ATTR{authorized}="0"
    '';
  };

  systemd.services.activate-touch-hack = {
    description = "Touch wake Thinkpad X1 Yoga 3rd gen hack";
    wantedBy = [
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend-then-hibernate.target"
    ];
    after = [
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend-then-hibernate.target"
    ];
    serviceConfig = {
      ExecStart = ''
        /bin/sh -c "echo '\\_SB.PCI0.LPCB.EC._Q2A'  > /proc/acpi/call"
      '';
    };
  };

  system.stateVersion = "22.05";
}
