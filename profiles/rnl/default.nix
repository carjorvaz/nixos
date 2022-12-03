{ config, lib, pkgs, ... }:

{
  services.wgrnl = {
    enable = true;
    privateKeyFile = "/persist/secrets/wireguard/privatekey";
  };
}
