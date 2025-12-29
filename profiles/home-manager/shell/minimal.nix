{ ... }:

# Minimal shell profile for environments with limited home-manager support (e.g., nix-on-droid)
{
  programs = {
    bat.enable = true;

    dircolors.enable = true;

    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    eza.enable = true;

    fzf.enable = true;

    starship.enable = true;

    zoxide.enable = true;
  };
}
