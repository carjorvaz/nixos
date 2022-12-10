{ config, inputs, lib, pkgs, suites, ... }:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@nerva"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMxNtlOg5VM8xN3XYfBGY3wIXrJ0vF5fBpc8s2NsLG9/ cjv@gallus"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINOSUI7+TSnSwzy3BI7uZm9p7/bS4Of0I7N70ITYgVd4 grapheneos"
  ];
in {
  imports = suites.batatus;

  fileSystems."/" = {
    device = "zroot/local/root";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/a17b977b-4956-4413-b9c3-50f30d0abf45";
    fsType = "ext4";
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

  # TODO migrate persistent folders to respective profile
  # tree -x / is helpful to check what is being erased.
  environment.persistence."/persist" = {
    hideMounts = true;
    files = [ "/etc/machine-id" ];
    directories = [
      "/var/www"
      "/var/lib/acme"
      "/var/lib/headscale"
      "/var/lib/nextcloud"
      "/var/lib/postgresql"
      "/var/lib/rpspamd"
      "/var/vmail"
      "/var/dkim"
    ];
  };

  boot = {
    initrd.availableKernelModules = [ "uhci_hcd" "ehci_pci" "ahci" "sd_mod" ];
    kernelModules = [ ];
    extraModulePackages = [ ];
    supportedFilesystems = [ "zfs" ];

    loader.grub = {
      enable = true;
      version = 2;
      device = "/dev/sda";
    };

    # Setup networking in the initrd.
    kernelParams = [ "ip=5.196.70.206::5.196.70.254:255.255.255.0::eth0:none" ];

    initrd = {
      # Erase your darlings.
      postDeviceCommands = lib.mkAfter ''
        zfs rollback -r zroot/local/root@blank
      '';

      supportedFilesystems = [ "zfs" ];
      kernelModules = [ "e1000e" ];
      network = {
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
          hostKeys = [ /persist/secrets/initrd/ssh_host_ed25519_key_initrd ];
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
  };

  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
  };

  networking = {
    hostId = "5130220d";

    usePredictableInterfaceNames = false;
    useDHCP = false;
    networkmanager.enable = false;

    interfaces.eth0 = {
      ipv4.addresses = [{
        address = "5.196.70.206";
        prefixLength = 24;
      }];

      ipv6.addresses = [{
        address = "2001:41d0:e:3ce::1";
        prefixLength = 128;
      }];
    };

    defaultGateway = "5.196.70.254";
    defaultGateway6 = {
      address = "2001:41d0:e:3ff:ff:ff:ff:ff";
      interface = "eth0";
    };
  };

  services = {
    openssh = {
      hostKeys = [
        {
          path = "/persist/etc/ssh/ssh_host_ed25519_key";
          type = "ed25519";
        }
        {
          path = "/persist/etc/ssh/ssh_host_rsa_key";
          type = "rsa";
          bits = 4096;
        }
      ];
    };
  };

  system.stateVersion = "21.11";
}
