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

  # Baseline intrusion banning on every server. NixOS adds the sshd jail when
  # openssh is enabled; mail/web jails stay in the edge profiles. Ignore
  # internal links and the tailnet (IPv4 and IPv6) so a proxied request or a
  # bad key on an internal host can never ban the bastion.
  services.fail2ban = {
    enable = lib.mkDefault true;

    ignoreIP = [
      "10.0.0.0/8" # pius LAN / unlock bridge
      "192.168.0.0/16"
      "100.64.0.0/10" # Tailscale IPv4
      "fd7a:115c:a1e0::/48" # Tailscale IPv6
    ];

    bantime = lib.mkDefault "24h";
    bantime-increment = {
      enable = lib.mkDefault true;
      formula = "ban.Time * math.exp(float(ban.Count+1)*banFactor)/math.exp(1*banFactor)";
      maxtime = "168h";
      overalljails = true;
    };
  };

  # Keep bans and the increment state across the ZFS root rollback.
  environment.persistence."/persist".directories = [
    "/var/lib/fail2ban"
    "/var/log/fail2ban"
  ];

  # No documentation on headless servers. `documentation.enable = false`
  # gates documentation.nix, but man-db is imported unconditionally and gated
  # only on `documentation.man.enable`: leaving that true installs man-db with
  # no /share/man links and builds an empty man cache. Disabling man turns off
  # the man-db module and its cache as well.
  documentation = {
    enable = lib.mkDefault false;
    man.enable = lib.mkDefault false;
  };

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
      ghostty.terminfo
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
