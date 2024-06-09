{
  self,
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ "${self}/profiles/home/zsh.nix" ];

  users.users = {
    cjv = {
      isNormalUser = true;
      createHome = true;
      description = "Carlos Vaz";
      extraGroups = [ "wheel" ];
      hashedPassword = lib.mkDefault "$y$j9T$g3eyg1O7rHF1NDBCj.hWl0$YthNr/9oRYmuE.2zChDL5nW6VjdNkUlcgDSjNh84aT/";
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP1OS3cOxw5+wleeTybg0sWE2z0pCj007rUO3kQHSVJ7 cjv@commodus"
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBK2AsWCLGKxGjkXbIUD8lIV0+48qJFNV9h7FfLLx16f cjv@trajanus"

        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINypN31r7gUkK+bo5S3h2dvHkqgwVfis6mmvBNaOFByE cjv@mac"
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBACMwCJmJqjPaReJswMLojtshrhr48h8BXOvBaS+k6sP1WXjln50Twn7fNW8i5lGXpA190hIYBo5tdF/kvE3JtE= cjv@iphone"
      ];
    };
  };

  home-manager.users.cjv.home.stateVersion = "23.11";
}
