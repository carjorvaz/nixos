{
  config,
  lib,
  pkgs,
  ...
}:

{
  home-manager.users.cjv = {
    programs = {
      zsh = {
        enable = true;
        autocd = true;
        defaultKeymap = "emacs";

        enableCompletion = true;
        enableVteIntegration = true;
        autosuggestion.enable = true;
        syntaxHighlighting.enable = true;

        history = {
          expireDuplicatesFirst = true;
          extended = true;
          ignoreDups = true;
        };
      };

      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      dircolors.enable = true;
      fzf.enable = true;
      starship.enable = true;
      zoxide.enable = true;
    };
  };
}
