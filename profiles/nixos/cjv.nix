{
  self,
  inputs,
  config,
  lib,
  ...
}:

let
  bootstrapPassword = config.cjv.bootstrap.initialHashedPassword;
  passwordFile = config.age.secrets.cjvHashedPassword.path;
in
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
      hashedPasswordFile = lib.mkIf (bootstrapPassword == null) (lib.mkDefault passwordFile);
      initialHashedPassword = lib.mkIf (bootstrapPassword != null) (
        lib.mkDefault bootstrapPassword
      );
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
      zellij.settings.theme = config.graphical.theme.appNames.zellij;
    };

    nix.registry = lib.mkDefault {
      nixpkgs.flake = inputs.nixpkgs;
      unstable.flake = inputs.nixpkgs-unstable;
    };

    home.stateVersion = lib.mkDefault "23.11";
  };
}
