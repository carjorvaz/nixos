{
  config,
  lib,
  pkgs,
  ...
}:

{
  # STATE: Run `tailscale up` on first boot.
  # Disable key expiry on the Tailscale console if necessary.
  services.tailscale.enable = true;
  networking.firewall = {
    checkReversePath = "loose";
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ config.services.tailscale.port ];
  };

  environment.persistence."/persist".directories = [ "/var/lib/tailscale" ];
}
