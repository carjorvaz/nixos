{ config, modulesPath, lib, pkgs, suites, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ]
    ++ suites.t440;

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "ehci_pci" "ahci" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "defaults" "size=2G" "mode=755" ];
  };

  fileSystems."/nix" = {
    device = "zroot/local/nix";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/persist" = {
    device = "zroot/safe/persist";
    fsType = "zfs";
    options = [ "zfsutil" ];
    neededForBoot = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/AA0B-CA9C";
    fsType = "vfat";
  };

  environment.persistence."/persist" = {
    hideMounts = true;
    files = [ "/etc/machine-id" ];
    directories = [ ];
  };

  boot.loader = {
    efi.canTouchEfiVariables = true;
    systemd-boot = {
      enable = true;
      editor = false;
      configurationLimit = 10;
    };
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
  };

  services.logind.lidSwitch = "ignore";

  networking.useDHCP = lib.mkDefault true;
  networking.hostId = "65db7b8e";
  # networking = {
  #   useDHCP = false;
  #   hostId = "65db7b8e";

  #   interfaces.enp0s25 = {
  #     useDHCP = false;
  #     wakeOnLan.enable = true; # Requires enabling WoL in BIOS

  #     ipv4.addresses = [{
  #       address = "192.168.1.2";
  #       prefixLength = 24;
  #     }];
  #   };

  #   defaultGateway = "192.168.1.254";
  # };

  virtualisation.docker.storageDriver = "zfs";

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  system.stateVersion = "23.05";
}
