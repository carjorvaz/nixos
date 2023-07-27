{ config, modulesPath, lib, pkgs, suites, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ]
    ++ suites.nerva;

  boot.initrd.availableKernelModules =
    [ "ahci" "ohci_pci" "ehci_pci" "xhci_pci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
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

  fileSystems."/boot1" = {
    device = "/dev/disk/by-uuid/33BC-29B9";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  fileSystems."/boot2" = {
    device = "/dev/disk/by-uuid/3399-302E";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  fileSystems."/boot3" = {
    device = "/dev/disk/by-uuid/3357-70C6";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  fileSystems."/boot4" = {
    device = "/dev/disk/by-uuid/3377-9DD9";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  fileSystems."/boot5" = {
    device = "/dev/disk/by-uuid/33DD-A196";
    fsType = "vfat";
    options = [ "nofail" ];
  };

  environment.persistence."/persist" = {
    hideMounts = true;
    files = [ "/etc/machine-id" ];
    directories = [ ];
  };

  boot.loader = {
    efi.canTouchEfiVariables = true;
    # grub = {
    #   enable = true;
    #   efiSupport = true;
    #   device = "nodev";
    #   mirroredBoots = [
    #     # {
    #     #   devices = [ "/dev/disk/by-uuid/33BC-29B9" ];
    #     #   path = "/boot";
    #     # }
    #     {
    #       devices = [ "/dev/disk/by-uuid/3399-302E" ];
    #       path = "/boot-1";
    #     }
    #     # {
    #     #   devices = [ "/dev/disk/by-uuid/3357-70C6" ];
    #     #   path = "/boot-2";
    #     # }
    #     # {
    #     #   devices = [ "/dev/disk/by-uuid/3377-9DD9" ];
    #     #   path = "/boot-3";
    #     # }
    #     # {
    #     #   devices = [ "/dev/disk/by-uuid/33DD-A196" ];
    #     #   path = "/boot-3";
    #     # }
    #   ];
    # };

    grub = {
      enable = true;
      # device = "nodev";
      efiSupport = true;
      # zfsSupport = true;
      mirroredBoots = [
        {
          devices = [ "nodev" ];
          path = "/boot1";
        }
        {
          devices = [ "nodev" ];
          path = "/boot2";
        }
        {
          devices = [ "nodev" ];
          path = "/boot3";
        }
        {
          devices = [ "nodev" ];
          path = "/boot4";
        }
        {
          devices = [ "nodev" ];
          path = "/boot5";
        }
      ];
    };
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;
  };

  networking = {
    useDHCP = false;
    hostId = "36d0d8f3";

    interfaces.enp2s0 = {
      useDHCP = false;
      wakeOnLan.enable = true; # Requires enabling WoL in BIOS

      ipv4.addresses = [{
        address = "192.168.1.2";
        prefixLength = 24;
      }];
    };

    defaultGateway = "192.168.1.254";
  };

  virtualisation.docker.storageDriver = "zfs";

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  system.stateVersion = "23.05";
}
