{
  config,
  lib,
  pkgs,
  ...
}:

let
  sshKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBK2AsWCLGKxGjkXbIUD8lIV0+48qJFNV9h7FfLLx16f cjv@trajanus"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKabE30sEDKJPK6Oq5zHn80qyakDSMqG3Y5tAfcUs2c9 cjv@mac"
    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEYD8N3akY3HZzv03LxEgnvctoeI6Z3MI9q4hL/m6IOE0LjXejJ3tYA56OYmRPitj73ks4I+ik7qpNHNZ6H/ktg= cjv@iphone"
  ];
in
{
  services.openssh = {
    enable = true;
    openFirewall = true;

    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };

    # Only allow SSH keys explictly set here, in the NixOS configuration.
    authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];
    hostKeys = [
      {
        path = "/persist/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  programs.mosh.enable = true;

  users.users.root.openssh.authorizedKeys.keys = sshKeys;
}
