{ config, lib, pkgs, ... }:

{
  # CachyOS server-lto kernel for all servers.
  boot.kernelPackages = lib.mkDefault pkgs.cachyosKernels.linuxPackages-cachyos-server-lto;
  boot.zfs.package = lib.mkDefault config.boot.kernelPackages.zfs_cachyos;

  # Servers use static IPs, no NetworkManager or WiFi.
  networking.networkmanager.enable = false;
  networking.wireless.enable = false;
  networking.useDHCP = lib.mkDefault false;

  # Disable documentation to save evaluation time on headless servers.
  documentation.enable = lib.mkDefault false;

  # No need for font rendering on servers.
  fonts.fontconfig.enable = lib.mkDefault false;

  # Disable desktop-oriented xdg file generation.
  xdg.autostart.enable = lib.mkDefault false;
  xdg.icons.enable = lib.mkDefault false;
  xdg.menus.enable = lib.mkDefault false;
  xdg.mime.enable = lib.mkDefault false;
  xdg.sounds.enable = lib.mkDefault false;

  # Don't install ld stubs on servers.
  environment.stub-ld.enable = lib.mkDefault false;

  # Print URLs instead of trying to open a browser.
  environment.variables.BROWSER = "echo";

  # Server troubleshooting tools + terminfo for desktop terminals (foot,
  # ghostty) so SSH sessions from the desktop render correctly.
  environment.systemPackages = with pkgs; [
    curl
    dnsutils
    foot.terminfo
  ];

  # Reduce firewall log noise.
  networking.firewall.logRefusedConnections = lib.mkDefault false;

  # Prevent accidental suspend/hibernate.
  systemd.sleep.extraConfig = ''
    AllowSuspend=no
    AllowHibernation=no
  '';

  # Force reboot if kexec hangs (some firmware doesn't support it).
  systemd.settings.Manager.KExecWatchdogSec = lib.mkDefault "1m";

  # Show serial console in nixos-rebuild build-vm.
  virtualisation.vmVariant.virtualisation.graphics = lib.mkDefault false;
}
