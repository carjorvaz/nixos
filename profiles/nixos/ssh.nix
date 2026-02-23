{ lib, ... }:

{
  services.openssh = {
    enable = true;
    openFirewall = true;

    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      X11Forwarding = false;
      UseDns = false;
      StreamLocalBindUnlink = true;
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

  users.users.root.openssh.authorizedKeys.keys = import ./ssh-keys.nix;
}
