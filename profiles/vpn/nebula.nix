{ self, config, lib, pkgs, ... }:

{

  age.secrets.nebulaRomeCaCrt.file = "${self}/secrets/nebulaRomeCaCrt.age";

  services.nebula.networks."rome" = {
    enable = true;
    ca = config.age.secrets.nebulaRomeCaCrt.path;
    lighthouses = [ "100.64.0.2" ];
    staticHostMap = { "100.64.0.2" = [ "46.38.242.172:4242" ]; };
    firewall = {
      inbound = [{
        host = "any";
        port = "any";
        proto = "any";
      }];
      outbound = [{
        host = "any";
        port = "any";
        proto = "any";
      }];
    };
  };

  networking.firewall = {
    checkReversePath = "loose";
    trustedInterfaces = [ "nebula.rome" ];
  };
}
