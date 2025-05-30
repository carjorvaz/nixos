{ ... }:

{
  home-manager.users.cjv = {
    home.shellAliases = {
      cat = "bat";
    };

    programs = {
      bat.enable = true;

      dircolors.enable = true;

      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      fzf.enable = true;

      eza.enable = true;

      starship.enable = true;

      yazi.enable = true;

      zellij = {
        settings = {
          theme = "gruvbox-dark";
          # default_layout = "compact";
          # on_force_close = "quit";
        };
      };

      zoxide.enable = true;
    };
  };
}
