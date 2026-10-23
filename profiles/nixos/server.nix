{
  config,
  lib,
  pkgs,
  ...
}:

{
  boot = {
    # Use the upstream default kernel and its matching ZFS module on servers.
    # The CachyOS server-lto kernel is never substituted and needs multi-hour
    # LTO builds plus the third-party lantian cache; desktops keep CachyOS via
    # graphical/performance.nix.
    kernelPackages = lib.mkDefault pkgs.linuxPackages;

    zfs = {
      # Preserve the historical root-pool import behavior explicitly. NixOS warns
      # that the default will flip to false in 26.11 to reduce data-loss risk.
      forceImportRoot = true;
    };
  };

  networking = {
    # Servers use static IPs, no NetworkManager or WiFi.
    networkmanager.enable = false;
    wireless.enable = false;
    useDHCP = lib.mkDefault false;
    # Reduce firewall log noise.
    firewall.logRefusedConnections = lib.mkDefault false;
  };

  # Firmware updates and removable-disk handling belong on physical desktops;
  # on servers they only consume memory and show up in the OOM victim pool.
  services = {
    fwupd.enable = lib.mkForce false;
    udisks2.enable = lib.mkForce false;
  };

  # Disable documentation to save evaluation time on headless servers.
  documentation.enable = lib.mkDefault false;

  # No need for font rendering on servers.
  fonts.fontconfig.enable = lib.mkDefault false;

  # Disable desktop-oriented xdg file generation.
  xdg = {
    autostart.enable = lib.mkDefault false;
    icons.enable = lib.mkDefault false;
    menus.enable = lib.mkDefault false;
    mime.enable = lib.mkDefault false;
    sounds.enable = lib.mkDefault false;
  };

  environment = {
    # Don't install ld stubs on servers.
    stub-ld.enable = lib.mkDefault false;

    # Print URLs instead of trying to open a browser.
    variables.BROWSER = "echo";

    # Server troubleshooting tools + terminfo for desktop terminals (foot,
    # ghostty) so SSH sessions from the desktop render correctly.
    systemPackages = with pkgs; [
      curl
      dnsutils
      foot.terminfo
    ];
  };

  systemd = {
    # Prevent accidental suspend/hibernate.
    sleep.settings.Sleep = {
      AllowSuspend = "no";
      AllowHibernation = "no";
    };

    # Force reboot if kexec hangs (some firmware doesn't support it).
    settings.Manager.KExecWatchdogSec = lib.mkDefault "1m";
  };

  # Show serial console in nixos-rebuild build-vm.
  virtualisation.vmVariant.virtualisation.graphics = lib.mkDefault false;
}
