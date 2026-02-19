{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Reference: https://wiki.archlinux.org/title/Fprint
  services.fprintd.enable = true;

  # Reference: https://discourse.nixos.org/t/problems-loging-in-with-password-when-fprint-is-enabled/65900
  security.pam.services.swaylock.rules.auth.fprintd.order =
    config.security.pam.services.swaylock.rules.auth.unix.order + 50;
  security.pam.services.sudo.rules.auth.fprintd.settings.timeout = 3;

  environment.persistence."/persist".directories = [ "/var/lib/fprint" ];
}
