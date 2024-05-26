{ self, config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    "${self}/profiles/nixos/base.nix"
    "${self}/profiles/nixos/bluetooth.nix"
    "${self}/profiles/nixos/bootloader/systemd-boot.nix"
    "${self}/profiles/nixos/cpu/intel.nix"
    "${self}/profiles/nixos/gpu/intel.nix"
    "${self}/profiles/nixos/iwd.nix"
    "${self}/profiles/nixos/dns/resolved.nix"
    "${self}/profiles/nixos/laptop.nix"
    "${self}/profiles/nixos/zfs/common.nix"
    "${self}/profiles/nixos/zramSwap.nix"

    "${self}/profiles/nixos/cjv.nix"
    "${self}/profiles/nixos/docker.nix"
    "${self}/profiles/nixos/emacs.nix"
    "${self}/profiles/nixos/graphical/sway.nix"
    "${self}/profiles/nixos/qmk.nix"
    "${self}/profiles/nixos/ssh.nix"

    # STATE: sudo tailscale up
    "${self}/profiles/nixos/tailscale.nix"
  ];

  boot.initrd.availableKernelModules =
    [ "xhci_pci" "ahci" "usb_storage" "sd_mod" "sdhci_pci" ];

  boot.kernelParams = [
    # Will kernel panic on suspend without this
    "i915.enable_dc=0"
  ];
  services.xserver = {
    # Scale of 100% is 96 dpi, steps of 12 are prefered
    dpi = 108;

    libinput.enable = false;

    synaptics = {
      enable = true;

      # References:
      # - https://gist.github.com/ivan/c35e798d4f32e37c1714ec5beec30d16
      # - https://wiki.archlinux.org/title/Touchpad_Synaptics#The_touchpad_is_not_working,_Xorg.0.log_shows_%22Query_no_Synaptics:_6003C8%22

      # xorg already has mouse acceleration ("pointer feedback"), so don't
      # let synaptics change speed.
      minSpeed = "1.0";
      maxSpeed = "1.0";

      # Default is 200/((WIDTH**2+HEIGHT**2)**0.5) and it may be better not
      # to mess with AccelFactor.
      accelFactor = "0.003";

      # Natural scrolling
      scrollDelta = -75;
      twoFingerScroll = true;

      fingersMap = [ 1 3 2 ];

      additionalOptions = ''
        Option "CircularScrolling" "on"
        Option "CircularPad" "on"

        # synaptics is too sensitive in general and MinSpeed=1.0 MaxSpeed=1.0
        # makes it worse, so use ConstantDeceleration (this is just a divisor!)
        # to slow it down to make precise movement possible.
        #
        # See also https://bugs.freedesktop.org/show_bug.cgi?id=38998
        # ("Synaptics driver imposes minimum speed")
        Option "ConstantDeceleration" "3"
      '';

      # We've slowed down the cursor quite a bit, so we need more than the
      # default acceleration of 2/1 to move it across the screen; add this
      # to ~/.xinitrc:
      #
      # xset m 4/1 0
      #
      # If your screen is big (these parameters were tested on 13" 1600x900),
      # you may need to increase the acceleration or decrease the
      # ConstantDeceleration so that you can flick the cursor across the screen.
    };
  };

  networking = {
    # Let iwd handle DHCP for Wi-Fi
    useDHCP = false;

    # But use dhcpcd for ethernet
    interfaces.enp0s31f6.useDHCP = true;

    hostName = "trajanus";
    hostId = "d7ba56e3";
  };

  services.thermald.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  system.stateVersion = "23.11";
}
