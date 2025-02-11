{
  config,
  lib,
  pkgs,
  ...
}:

{
  home-manager.users.cjv = {
    programs = {
      dircolors.enable = true;

      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      eza.enable = true;

      fzf.enable = true;

      starship.enable = true;

      zellij = {
        settings = {
          theme = "gruvbox-dark";
          # default_layout = "compact";
          # on_force_close = "quit";
        };
      };

      zoxide.enable = true;

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
    };
  };
}
