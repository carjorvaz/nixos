{
  self,
  inputs,
  lib,
  ...
}:

{
  users.users = {
    cjv = {
      isNormalUser = true;
      createHome = true;
      description = "Carlos Vaz";
      extraGroups = [
        "audio"
        "wheel"

        # For using this tool: https://xteink.dve.al/
        # Reference: https://wiki.nixos.org/wiki/Serial_Console
        "dialout"
      ];
      hashedPassword = lib.mkDefault "$y$j9T$g3eyg1O7rHF1NDBCj.hWl0$YthNr/9oRYmuE.2zChDL5nW6VjdNkUlcgDSjNh84aT/";
      openssh.authorizedKeys.keys = import ./ssh-keys.nix;
    };
  };

  home-manager.users.cjv = {
    imports = [
      "${self}/profiles/home-manager/neovim.nix"
      "${self}/profiles/home-manager/shell/fish.nix"
    ];

    programs = {
      delta = {
        enable = true;
        enableGitIntegration = true;
      };
      gitui.enable = true;
      ssh.enableDefaultConfig = false;
      zellij.settings.theme = "gruvbox-dark";
    };

    nix.registry = lib.mkDefault {
      nixpkgs.flake = inputs.nixpkgs;
      unstable.flake = inputs.nixpkgs-unstable;
    };

    home.stateVersion = lib.mkDefault "23.11";
  };
}
