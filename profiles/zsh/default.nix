{ config, lib, pkgs, ... }:

{
  programs = {
    zsh = {
      enable = true;

      vteIntegration = true;
      enableBashCompletion = true;
      autosuggestions.enable = true;
      syntaxHighlighting.enable = true;

      setOptions =
        [ "HIST_IGNORE_DUPS" "SHARE_HISTORY" "HIST_FCNTL_LOCK" "EMACS" ];

      shellInit = ''
        # Completion based on man pages
        zstyle ':completion:*:manuals'    separate-sections true
        zstyle ':completion:*:manuals.*'  insert-sections   true
        zstyle ':completion:*:man:*'      menu yes select

        # Delete words like bash
        autoload -U select-word-style
        select-word-style bash
      '';
    };

    starship.enable = true;
  };

  environment.pathsToLink = [ "/share/zsh" ]; # For zsh completion
  users.defaultUserShell = pkgs.zsh;
}
