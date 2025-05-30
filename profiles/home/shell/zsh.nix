{ ... }:

{
  imports = [ ./common.nix ];

  home-manager.users.cjv.programs = {
    fzf.enable = true;
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
}
