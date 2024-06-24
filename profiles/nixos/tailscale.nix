{
  config,
  lib,
  pkgs,
  ...
}:

{
  # STATE: Run `tailscale up` on first boot.
  # Disable key expiry on the Tailscale console if necessary.
  services.tailscale = {
    enable = true;
    openFirewall = true;
    useRoutingFeatures = lib.mkDefault "client";
  };

  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  environment.persistence."/persist".directories = [ "/var/lib/tailscale" ];
}
