{
  self,
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  networkInterface = "enp4s0";
in
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/amd.nix"
    "${self}/profiles/nixos/gpu/nvidia.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/fail2ban.nix"

    "${self}/profiles/nixos/cjv.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/graphical/cosmic.nix"
    "${self}/profiles/nixos/docker.nix"
    "${self}/profiles/nixos/libvirt.nix"
    "${self}/profiles/nixos/printing.nix"
    "${self}/profiles/nixos/ssh.nix"

    "${self}/profiles/home/zsh.nix"
  ];

  age.secrets.aureliusInitrdHostKey.file = "${self}/secrets/aureliusInitrdHostKey.age";

  # For old SSH
  # STATE: ❯ nix registry add nixpkgs2205 github:nixos/nixpkgs/nixos-22.05

  # # TODO declarative, currently broken
  # nix.registry.nixpkgs2205.flake.url = "github:nixos/nixpkgs/nixos-22.05";

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usb_storage"
    "usbhid"
    "sd_mod"
  ];

  hardware.nvidia.package = lib.mkDefault config.boot.kernelPackages.nvidiaPackages.beta;

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

      ipv4.addresses = [
        {
          address = "193.136.164.202";
          prefixLength = 27;
        }
      ];

      ipv6.addresses = [
        {
          address = "2001:690:2100:82::202";
          prefixLength = 64;
        }
      ];
    };

    defaultGateway = "193.136.164.222";
    defaultGateway6 = "2001:690:2100:82::ffff:1";

    nameservers = [
      "193.136.164.1"
      "193.136.164.2"
      "2001:690:2100:82::1"
      "2001:690:2100:82::2"
    ];

    vlans.management = {
      id = 1;
      interface = networkInterface;
    };

    interfaces.management.ipv4.addresses = [
      {
        address = "192.168.102.202";
        prefixLength = 22;
      }
    ];
  };

  security.pki.certificateFiles =
    let
      RNLCert = builtins.fetchurl {
        url = "https://rnl.tecnico.ulisboa.pt/ca/cacert/cacert.pem";
        sha256 = "1jiqx6s86hlmpp8k2172ki6b2ayhr1hyr5g2d5vzs41rnva8bl63";
      };
    in
    [ "${RNLCert}" ];

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
      address = (builtins.head config.networking.interfaces.${networkInterface}.ipv4.addresses).address;
      gateway = config.networking.defaultGateway.address;
      # TODO automatically set this according to prefixLength above
      netmask = "255.255.255.224";
      interface = networkInterface;
    };
  };

  users.users.cjv.hashedPassword = "$y$j9T$tJQ1YunPkcr0P2ay/PHqP.$OLGalRqTmS8q0goP6N5jBa0YvUJrdQ0/WDoNdBYPTD5";

  nix.gc.automatic = lib.mkForce false;

  home-manager.users.cjv = {
    home.stateVersion = "24.05";

    programs = {
      i3status-rust.bars.top.blocks = [
        {
          block = "sound";
          max_vol = 100;
          headphones_indicator = true;
          device_kind = "sink";
          click = [
            {
              button = "left";
              cmd = "${pkgs.rofi-pulse-select}/bin/rofi-pulse-select sink";
            }
          ];
        }
        {
          block = "time";
          interval = 5;
          format = " $timestamp.datetime(f:'%a %d/%m %R')";
        }
      ];

      ssh = {
        enable = true;
        extraConfig = ''
          CanonicalizeHostname yes
          CanonicalDomains rnl.tecnico.ulisboa.pt
          CanonicalizeMaxDots 0

          Match canonical host="*.rnl.tecnico.ulisboa.pt"
            User root
            SendEnv RNLADMIN
            ServerAliveInterval 60

          Host *.rnl.tecnico.ulisboa.pt *.rnl.ist.utl.pt
            User root
            SendEnv RNLADMIN
            ServerAliveInterval 60
        '';
      };
    };

    services.nextcloud-client.enable = false;

    wayland.windowManager = {
      hyprland.settings = {
        monitor = [
          "HDMI-A-1, preferred, 0x45, 1.6"
          "DP-3, preferred, 1602x0, 2"
        ];

        workspace = [
          "10, monitor:HDMI-A-1, default:true"
        ];
      };

      sway.config = rec {
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

        workspaceOutputAssign = [
          {
            workspace = "9";
            output = "HDMI-A-2";
          }
        ];
      };
    };
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "24.05";
}
