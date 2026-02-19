{ ... }:

# Portable shell config - works on NixOS, Darwin, and nix-on-droid
{
  programs = {
    bat.enable = true;

    dircolors.enable = true;

    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };

    eza.enable = true;

    fd = {
      enable = true;
      hidden = true;
      ignores = [
        ".git/"
        ".cache/"
        ".direnv/"
      ];
    };

    fzf = {
      enable = true;
      defaultCommand = "fd --type f --hidden";
      fileWidgetCommand = "fd --type f --hidden";
      changeDirWidgetCommand = "fd --type d --hidden";
    };

    starship.enable = true;

    yazi.enable = true;

    zellij.enable = true;

    zoxide.enable = true;
  };
}
