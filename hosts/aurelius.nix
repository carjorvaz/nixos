# Do not modify this file!  It was generated by ‘nixos-generate-config’
# and may be overwritten by future invocations.  Please make changes
# to /etc/nixos/configuration.nix instead.
{ config, lib, pkgs, modulesPath, suites, ... }:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMxNtlOg5VM8xN3XYfBGY3wIXrJ0vF5fBpc8s2NsLG9/ cjv@gallus"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINOSUI7+TSnSwzy3BI7uZm9p7/bS4Of0I7N70ITYgVd4 grapheneos"

    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICjVjQULxTJ+NN5ekG0HLpnkyPFIAwbNCQ5EOZ4cSfCt root@gallus" # Distributed builds.
  ];
in {
  imports = suites.aurelius
    ++ [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];
  boot.supportedFilesystems = [ "zfs" ];

  fileSystems."/" = {
    device = "zroot/local/root";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/A6B2-C596";
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
    cpu.amd.updateMicrocode = true;
  };

  boot = {
    kernelParams =
      [ "ip=193.136.164.194::193.136.164.222:255.255.255.224::enp4s0:none" ];
    initrd.availableKernelModules =
      [ "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
    initrd.supportedFilesystems = [ "zfs" ];
    initrd.kernelModules = [ "r8169" ];
    initrd.network = {
      # This will use udhcp to get an ip address.
      # Make sure you have added the kernel module for your network driver to `boot.initrd.availableKernelModules`,
      # so your initrd can load it!
      # Static ip addresses might be configured using the ip argument in kernel command line:
      # https://www.kernel.org/doc/Documentation/filesystems/nfs/nfsroot.txt
      enable = true;
      ssh = {
        enable = true;
        # To prevent ssh clients from freaking out because a different host key is used,
        # a different port for ssh is useful (assuming the same host has also a regular sshd running)
        port = 2222;
        # hostKeys paths must be unquoted strings, otherwise you'll run into issues with boot.initrd.secrets
        # the keys are copied to initrd from the path specified; multiple keys can be set
        # you can generate any number of host keys using
        # `ssh-keygen -t ed25519 -N "" -f /path/to/ssh_host_ed25519_key`
        hostKeys =
          [ /persist/secrets/initrd/ssh_host_ed25519_key_initrd ]; # TODO agenix
        # public ssh key used for login
        authorizedKeys = sshKeys;
      };
      # this will automatically load the zfs password prompt on login
      # and kill the other prompt so boot can continue
      postCommands = ''
        cat <<EOF > /root/.profile
        if pgrep -x "zfs" > /dev/null
        then
          zfs load-key -a
          killall zfs
        else
          echo "zfs not running -- maybe the pool is taking some time to load for some unforseen reason."
        fi
        EOF
      '';
    };
  };

  nix.settings.trusted-users =
    [ "root" "@wheel" ]; # Required for distributed builds.

  networking = {
    networkmanager.enable = false;

    hostId = "8556b001";
    domain = "rnl.tecnico.ulisboa.pt";

    useDHCP = false;
    interfaces.enp4s0 = {
      useDHCP = false;
      wakeOnLan.enable = true;

      ipv4.addresses = [{
        address = "193.136.164.194";
        prefixLength = 27;
      }];

      ipv6.addresses = [{
        address = "2001:690:2100:82::194";
        prefixLength = 64;
      }];
    };

    defaultGateway = "193.136.164.222";
    defaultGateway6 = {
      address = "2001:690:2100:82::ffff:1";
      interface = "enp4s0";
    };

    nameservers = [
      "193.136.164.1"
      "193.136.164.2"
      "2001:690:2100:82::1"
      "2001:690:2100:82::2"
    ];

    search = [ "rnl.tecnico.ulisboa.pt" ];
  };

  home-manager.users.cjv = {
    # TODO:
    # - natural scrolling only on gallus; change on common
    # - increase font size
    programs.i3status-rust.bars.top.blocks = [
      {
        block = "sound";
        max_vol = 100;
        headphones_indicator = true;
        device_kind = "sink";
      }
      {
        block = "sound";
        max_vol = 100;
        device_kind = "source";
      }
      {
        block = "time";
        interval = 5;
        format = "%a %d/%m %R";
      }
    ];

    wayland.windowManager.sway.config = rec {
      output = {
        "*".bg = "~/Pictures/wallpaper.png fill";
        "HDMI-A-1" = {
          resolution = "2560x1440";
          pos = "0 215";
        };
        "VGA-1" = {
          resolution = "1920x1080";
          pos = "2560 0";
          transform = "270";
        };
      };

      workspaceOutputAssign = [{
        workspace = "9";
        output = "VGA-1";
      }];
    };
  };

  system.stateVersion = "21.11";
}
