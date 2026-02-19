{ ... }:

# NOTE: TCC is useless on the WUJIE14XA (TUXEDO InfinityBook Pro 14 Gen9 AMD).
# The firmware doesn't expose platform_profile, fan control, or keyboard backlight.
# The daemon (Node.js 14, ~43MB RAM) runs but does nothing.
# Use TLP for AC/battery power switching instead (see laptop.nix).
{
  # Disable power-profiles-daemon to prevent conflicts with TUXEDO Control Center.
  # TCC needs exclusive control over CPU frequencies and governors.
  services.power-profiles-daemon.enable = false;

  # TUXEDO Control Center for platform profile control.
  # Provides firmware-level profile switching and CPU frequency management.
  hardware.tuxedo-control-center.enable = true;

  # Persist TCC settings and profiles across reboots (for impermanence setups).
  environment.persistence."/persist".directories = [
    "/var/lib/tcc"
  ];
}
