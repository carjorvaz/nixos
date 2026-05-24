{
  self,
  pkgs,
  ...
}:

{
  home-manager.users.cjv.imports = [
    "${self}/profiles/home-manager/shell/fish.nix"
  ];

  environment.systemPackages = with pkgs; [
    grc
  ];

  home-manager.users.cjv.programs.fish.plugins = [
    {
      name = "done";
      src = pkgs.fishPlugins.done.src;
    }
    {
      name = "grc";
      src = pkgs.fishPlugins.grc.src;
    }
  ];

  programs = {
    fish = {
      enable = true;

      shellInit = ''
        # GUI apps such as cmux can inherit nix-darwin/Home Manager "already
        # sourced" sentinels from a parent process whose PATH was later pruned.
        # Repair PATH before Home Manager installs hooks such as zoxide.
        if set -q __NIX_DARWIN_SET_ENVIRONMENT_DONE
          if not contains -- "/etc/profiles/per-user/$USER/bin" $PATH
            fish_add_path --path --move --prepend \
              "$HOME/.nix-profile/bin" \
              "/etc/profiles/per-user/$USER/bin" \
              "/run/current-system/sw/bin" \
              "/nix/var/nix/profiles/default/bin"
          end
        end

        # If Home Manager's session-vars sentinel is stale too, let HM source
        # its generated fish session variables before interactive hooks run.
        if set -q __HM_SESS_VARS_SOURCED
          if not contains -- "$HOME/.local/bin" $PATH
            set -e __HM_SESS_VARS_SOURCED
          end
        end
      '';

      interactiveShellInit = "set fish_greeting"; # Disable greeting
    };
  };
}
