{ self, ... }:

{

  imports = [ "${self}/profiles/home/shell/zsh.nix" ];

  programs.zsh = {
    enable = true;

    enableBashCompletion = true;
    enableCompletion = true;
    enableFzfCompletion = true;
    enableFzfHistory = true;
    enableSyntaxHighlighting = true;

    shellInit = ''
      # Make sure brew is on the path for M1.
      if [[ $(uname -m) == 'arm64' ]]; then
           eval "$(/opt/homebrew/bin/brew shellenv)"
      fi
    '';
  };
}
