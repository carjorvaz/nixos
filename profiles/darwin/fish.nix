{
  self,
  pkgs,
  config,
  ...
}:

{
  home-manager.users.cjv = {
    imports = [
      "${self}/profiles/home-manager/shell/fish.nix"
    ];

    # Upstream installers publish launchers into ~/.local/bin (Hermes' `hermes`,
    # Ardia's CLI). This line is also load-bearing for the Hermes bootstrap: its
    # wire_shell_path step appends exactly this to ~/.config/fish/config.fish
    # unless the file already matches `^[[:space:]]*fish_add_path.*\.local/bin`,
    # and appending to this Home Manager symlink is a permission error. Keep the
    # spelling; the nix-darwin-level `programs.fish` above writes
    # /etc/fish/config.fish, which the installer never looks at.
    programs.fish.shellInit = ''fish_add_path "$HOME/.local/bin"'';

    programs.fish.plugins = [
      {
        name = "done";
        src = pkgs.fishPlugins.done.src;
      }
      {
        name = "grc";
        src = pkgs.fishPlugins.grc.src;
      }
    ];
  };

  environment.systemPackages = with pkgs; [
    grc
  ];

  programs.fish = {
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

      # API keys decrypted by agenix
      set -gx BRAVE_SEARCH_API_KEY (cat ${config.age.secrets.braveSearchApiKey.path} 2>/dev/null || true)
      set -gx BRAVE_API_KEY "$BRAVE_SEARCH_API_KEY"
    '';

    interactiveShellInit = "set fish_greeting"; # Disable greeting
  };

  age.secrets = {
    braveSearchApiKey = {
      file = "${self}/secrets/brave-search-api-key.age";
      owner = "cjv";
      mode = "0400";
    };
  };

  # agenix defaults to /etc/ssh host keys, which don't exist on macOS
  age.identityPaths = [ "/Users/cjv/.ssh/id_ed25519" ];
}
