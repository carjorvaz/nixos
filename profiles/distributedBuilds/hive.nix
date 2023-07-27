{ config, lib, pkgs, ... }:

{
  # Only use on encrypted systems.
  # Requires adding the ssh host key (root) to aurelius.
  nix = {
    distributedBuilds = true;
    buildMachines = [{
      hostName = "10.16.89.2";
      sshUser = "root";
      sshKey = "/etc/ssh/ssh_host_ed25519_key";
      systems = [ "x86_64-linux" "aarch64-linux" ];
      maxJobs = 10;
      speedFactor = 2;
      supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
      mandatoryFeatures = [ ];
    }];
    extraOptions = ''
      builders-use-substitutes = true
    '';
  };
}
