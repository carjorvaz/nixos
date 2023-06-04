{ self, config, inputs, lib, modulesPath, pkgs, suites, ... }:
let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINOSUI7+TSnSwzy3BI7uZm9p7/bS4Of0I7N70ITYgVd4 grapheneos"
  ];
in {
  imports = suites.hadrianus ++ [ (modulesPath + "/profiles/qemu-guest.nix") ];

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "defaults" "size=2G" "mode=755" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/3CAE-7149";
    fsType = "vfat";
  };

  fileSystems."/nix" = {
    device = "rpool/local/nix";
    fsType = "zfs";
    options = [ "zfsutil" ];
  };

  fileSystems."/persist" = {
    device = "rpool/safe/persist";
    fsType = "zfs";
    options = [ "zfsutil" ];
    neededForBoot = true;
  };

  environment.persistence."/persist" = {
    hideMounts = true;
    files = [ "/etc/machine-id" ];
    directories = [ ];
  };

  boot = {
    loader = {
      systemd-boot.enable = true;
      efi.canTouchEfiVariables = true;
    };

    initrd.availableKernelModules =
      [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
    supportedFilesystems = [ "zfs" ];

    # Setup networking in the initrd.
    kernelParams = [ "ip=46.38.242.172::46.38.240.1:255.255.252.0::ens3:none" ];

    initrd = {
      kernelModules = [ "virtio_pci" ];
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
          hostKeys =
            [ /persist/etc/ssh/ssh_host_ed25519_key_initrd ]; # TODO agenix?
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

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware = {
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;
  };

  networking = {
    hostId = "ce9c10db";
    networkmanager.enable = false;
    useDHCP = false;

    interfaces.ens3 = {
      useDHCP = false;

      ipv4.addresses = [{
        address = "46.38.242.172";
        prefixLength = 22;
      }];

      ipv6.addresses = [{
        address = "2a03:4000:7:68::";
        prefixLength = 64;
      }];
    };

    defaultGateway = "46.38.240.1";
  };

  age.secrets.nebulaRomeHadrianusCrt.file =
    "${self}/secrets/nebulaRomeHadrianusCrt.age";
  age.secrets.nebulaRomeHadrianusKey.file =
    "${self}/secrets/nebulaRomeHadrianusKey.age";

  services.nebula.networks."rome" = {
    isLighthouse = true;
    cert = config.age.secrets.nebulaRomeHadrianusCrt.path;
    key = config.age.secrets.nebulaRomeHadrianusKey.path;
  };

  system.stateVersion = "22.11";
}
