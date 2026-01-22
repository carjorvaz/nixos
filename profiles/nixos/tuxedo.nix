{ ... }:

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
