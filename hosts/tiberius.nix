{
  self,
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

let
  # USB Ethernet (Realtek r8152). The onboard RJ45 is BMC-only (NC-SI sideband);
  # the host has no wired NIC of its own.
  iface = "enp0s20f0u5";
in
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/server.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/ssh.nix"
    "${self}/profiles/nixos/zramSwap.nix"
    # STATE: sudo tailscale up (first auth is manual)
    "${self}/profiles/nixos/tailscale.nix"
  ];

  boot = {
    # TEMPORARY: stock kernel/zfs pair from cache.nixos.org. server.nix's
    # CachyOS server-lto default has no substituter and must build remotely;
    # the remote builders are wired (pius/trajanus via remote-builder.nix) and
    # signature trust is proven, but pius currently drops connections from
    # this host and trajanus is disk-full. Flip to cachyosKernels (delete this
    # override) once either builder can serve tiberius, then `nix copy` the
    # closure or rebuild via the configured buildMachines.
    kernelPackages = lib.mkForce pkgs.linuxPackages;
    zfs.package = lib.mkForce pkgs.zfs;
    initrd.availableKernelModules = [
      "xhci_pci"
      "ahci"
      "nvme"
      "usb_storage"
      "sd_mod"
    ];
    zfs.extraPools = [ "zdata" ];
  };

  networking = {
    hostName = "tiberius";
    hostId = "5eed08d7";
    # Global useDHCP defaults to true, which lets dhcpcd claim every interface
    # and silently ignores per-interface static addresses.
    useDHCP = false;
    defaultGateway = "192.168.1.1";
    nameservers = [ "192.168.1.1" ];
    # Static in the low zone next to the remoteUnlock .2 precedent: the router
    # DHCP pool demonstrably covers .140-.217, so "next to trajanus" (.172)
    # would collide. Wake path is the BMC, not the NIC: the USB NIC cannot
    # signal wake, so power-on goes through IPMI (ipmitool -I lanplus ...).
    interfaces.${iface} = {
      useDHCP = false;
      ipv4.addresses = [
        {
          address = "192.168.1.3";
          prefixLength = 24;
        }
      ];
    };
  };

  nix = {
    settings.builders = [ "@/etc/nix/machines" ];
    distributedBuilds = true;
    # Builders over the tailnet; reachable once `sudo tailscale up` has run.
    buildMachines = [
      {
        hostName = "trajanus";
        sshUser = "nix-ssh";
        sshKey = "/persist/etc/ssh/builder@tiberius";
        systems = [ "x86_64-linux" ];
        protocol = "ssh-ng";
        maxJobs = 8;
        speedFactor = 3;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
      }
      {
        hostName = "pius";
        sshUser = "nix-ssh";
        sshKey = "/persist/etc/ssh/builder@tiberius";
        systems = [ "x86_64-linux" ];
        protocol = "ssh-ng";
        maxJobs = 6;
        speedFactor = 2;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
      }
    ];
    settings.trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "tiberius-builder-pius:Q6Ykvkqf0OoLCFqNMwjCns04A8OK+sOaZK0Tmy7ZMRE="
      "tiberius-builder-trajanus:njMvtYYB/ZQbSrjzquwrsuaclPHvIVxLmtJ1bPdyJOU="
    ];
  };

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "26.05";
}
