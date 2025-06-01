{ self, pkgs, ... }:

{
  imports = [ "${self}/profiles/home/shell/fish.nix" ];

  environment.systemPackages = with pkgs; [
    fishPlugins.done
    # fishPlugins.fzf-fish # Broken: https://github.com/NixOS/nixpkgs/issues/410069
    fishPlugins.grc
    grc
  ];

  programs = {
    fish = {
      enable = true;

      interactiveShellInit = ''
        set fish_greeting # Disable greeting

        # Make sure brew is on the path for M1.
        if test (uname -m) = "arm64"
            eval (/opt/homebrew/bin/brew shellenv)
        end
      '';
    };

    zsh.interactiveShellInit = ''
      if [[ $(ps -o command= -p "$PPID" | awk '{print $1}') != 'fish' ]]
      then
          exec fish -l
      fi
    '';
  };
}
