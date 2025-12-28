{ ... }:

{
  programs = {
    bat.enable = true;

    delta = {
      enable = true;
      enableGitIntegration = true;
    };

    dircolors.enable = true;

    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    eza.enable = true;

    fzf.enable = true;

    gitui.enable = true;

    starship.enable = true;

    yazi.enable = true;

    zellij = {
      settings = {
        theme = "gruvbox-dark";
      };
    };

    zoxide.enable = true;
  };
}
