{ config, lib, pkgs, ... }:

{
  services.resolved = {
    enable = true;
    extraConfig = ''
      DNS=1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001
      Domains=~.
    '';
  };
}
