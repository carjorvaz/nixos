{ pkgs, ... }:

# Portable shell config - works on NixOS and Darwin
{
  home.packages = with pkgs; [
    just
    jujutsu
  ];

  programs = {
    bat.enable = true;

    btop.enable = true;

    htop.enable = true;

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

    delta = {
      enable = true;
      enableGitIntegration = true;
    };

    git = {
      enable = true;
      signing.format = "openpgp";
      settings.init.defaultBranch = "master";
    };

    fzf = {
      enable = true;
      defaultCommand = "fd --type f --hidden";
      fileWidgetCommand = "fd --type f --hidden";
      changeDirWidgetCommand = "fd --type d --hidden";
    };

    starship.enable = true;

    yazi = {
      enable = true;
      shellWrapperName = "y";
    };

    zellij.enable = true;

    zoxide.enable = true;
  };
}
