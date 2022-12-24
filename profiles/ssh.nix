{ config, lib, pkgs, self, ... }:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMxNtlOg5VM8xN3XYfBGY3wIXrJ0vF5fBpc8s2NsLG9/ cjv@gallus"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINOSUI7+TSnSwzy3BI7uZm9p7/bS4Of0I7N70ITYgVd4 grapheneos"
  ];
in {
  services.openssh = {
    enable = true;
    openFirewall = true;
    passwordAuthentication = false;
    kbdInteractiveAuthentication = false;
    # Only allow ssh keys explictly set here, in the NixOS configuration.
    authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
  };

  users.users.cjv.openssh.authorizedKeys.keys = sshKeys;
  users.users.root.openssh.authorizedKeys.keys = sshKeys;
}
