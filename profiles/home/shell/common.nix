{ ... }:

{
  home-manager.users.cjv = {
    programs = {
      bat.enable = true;

      dircolors.enable = true;

      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      eza.enable = true;

      fzf.enable = true;

      git.delta.enable = true;

      gitui.enable = true;

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
