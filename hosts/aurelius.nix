{ self, config, lib, pkgs, modulesPath, ... }:

let networkInterface = "eno1";
in {
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/gpu/intel.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/emacs.nix"
    # Could prefer sway but doesn't work well with proprietary Nvidia drivers.
    "${self}/profiles/nixos/graphical/sway.nix"
    "${self}/profiles/nixos/printing.nix"
    "${self}/profiles/nixos/qmk.nix"

    "${self}/profiles/nixos/docker.nix"
    "${self}/profiles/nixos/libvirt.nix"
    "${self}/profiles/nixos/nginx/common.nix"
    "${self}/profiles/nixos/ssh.nix"

    "${self}/profiles/home/zsh.nix"
  ];

  age.secrets.aureliusInitrdHostKey.file =
    "${self}/secrets/aureliusInitrdHostKey.age";

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "ahci" "nvme" "usb_storage" "sd_mod" ];

  networking = {
    useDHCP = false;
    hostName = "aurelius";
    hostId = "8556b001";

    networkmanager.enable = false;

    domain = "rnl.tecnico.ulisboa.pt";
    search = [ "rnl.tecnico.ulisboa.pt" ];
    timeServers = [ "ntp.rnl.tecnico.ulisboa.pt" ];

    interfaces.${networkInterface} = {
      useDHCP = false;
      wakeOnLan.enable = true; # Requires enabling WoL in BIOS

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
    defaultGateway6 = "2001:690:2100:82::ffff:1";

    nameservers = [
      "193.136.164.1"
      "193.136.164.2"
      "2001:690:2100:82::1"
      "2001:690:2100:82::2"
    ];
  };

  security.pki.certificateFiles = let
    RNLCert = builtins.fetchurl {
      url = "https://rnl.tecnico.ulisboa.pt/ca/cacert/cacert.pem";
      sha256 = "1jiqx6s86hlmpp8k2172ki6b2ayhr1hyr5g2d5vzs41rnva8bl63";
    };
  in [ "${RNLCert}" ];

  # STATE: Comment this block when deploying, as agenix won't be able to get the
  # host keys and won't create the boot entry.
  # After deploying, enable again and rebuild.
  cjv.zfsRemoteUnlock = {
    enable = true;
    # As most firewall ports are blocked,
    # use a more common one that still isn't 22.
    port = 80;
    authorizedKeys = config.users.users.cjv.openssh.authorizedKeys.keys;
    hostKeyFile = config.age.secrets.aureliusInitrdHostKey.path;
    driver = "r8169";
    static = {
      enable = true;
      # Gets the first IP address from the system network configuration.
      address = (builtins.head
        config.networking.interfaces.${networkInterface}.ipv4.addresses).address;
      gateway = config.networking.defaultGateway.address;
      # TODO automatically set this according to prefixLength above
      netmask = "255.255.255.224";
      interface = networkInterface;
    };
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";

  users.users = {
    cjv = {
      isNormalUser = true;
      description = "Carlos Vaz";
      extraGroups = [ "wheel" ];
      hashedPassword =
        "$y$j9T$tJQ1YunPkcr0P2ay/PHqP.$OLGalRqTmS8q0goP6N5jBa0YvUJrdQ0/WDoNdBYPTD5";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID7sTv+M2QPe4bLAQTeHhAxGVVBmQes74PIXIE3o4bLl cjv@trajanus"

        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINypN31r7gUkK+bo5S3h2dvHkqgwVfis6mmvBNaOFByE cjv@mac"
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBACMwCJmJqjPaReJswMLojtshrhr48h8BXOvBaS+k6sP1WXjln50Twn7fNW8i5lGXpA190hIYBo5tdF/kvE3JtE= cjv@iphone"
      ];
    };
  };

  home-manager.users.cjv = {
    home.stateVersion = "23.11";

    programs.i3status-rust.bars.top.blocks = [
      {
        block = "sound";
        max_vol = 100;
        headphones_indicator = true;
        device_kind = "sink";
        click = [{
          button = "left";
          cmd = "${pkgs.rofi-pulse-select}/bin/rofi-pulse-select sink";
        }];
      }
      {
        block = "time";
        interval = 5;
        format = " $timestamp.datetime(f:'%a %d/%m %R')";
      }
    ];

    wayland.windowManager.sway.config = rec {
      output = {
        "*".bg = "~/Pictures/wallpaper.png fill";

        "DP-1" = {
          resolution = "3840x2160";
          # Get pos from wdisplays.
          pos = "0 86";
          scale = "1.25";
        };

        "HDMI-A-2" = {
          resolution = "1920x1080";
          # Get pos from wdisplays.
          pos = "3072 0";
          transform = "270";
        };
      };

      workspaceOutputAssign = [{
        workspace = "9";
        output = "HDMI-A-2";
      }];
    };
  };

  system.stateVersion = "21.11";
}
