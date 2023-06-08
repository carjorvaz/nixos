{ config, lib, pkgs, self, ... }:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINypN31r7gUkK+bo5S3h2dvHkqgwVfis6mmvBNaOFByE cjv@mac"
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBACMwCJmJqjPaReJswMLojtshrhr48h8BXOvBaS+k6sP1WXjln50Twn7fNW8i5lGXpA190hIYBo5tdF/kvE3JtE= cjv@iphone"
  ];
in {
  services.openssh = {
    enable = true;
    openFirewall = true;

    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };

    # Only allow ssh keys explictly set here, in the NixOS configuration.
    authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
    hostKeys = [{
      path = "/persist/etc/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }];
  };

  programs.mosh.enable = true;

  users.users.cjv.openssh.authorizedKeys.keys = sshKeys;
  users.users.root.openssh.authorizedKeys.keys = sshKeys;
}
