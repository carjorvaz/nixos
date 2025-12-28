{
  self,
  pkgs,
  ...
}:

# Bootstrapping:
# 1. Install nix-on-droid from F-Droid or GitHub releases
# 2. Clone this repo to ~/.config/nixos (or your preferred location)
# 3. Run: nix-on-droid switch --flake ~/.config/nixos
{
  system.stateVersion = "24.05";

  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  environment.packages = with pkgs; [
    # Core utilities
    coreutils
    diffutils
    findutils
    gnugrep
    gnused
    gnutar
    gzip

    # Development tools
    git
    openssh

    # Shell utilities
    fd
    ripgrep
    htop
  ];

  terminal.font = "${pkgs.nerd-fonts.jetbrains-mono}/share/fonts/truetype/NerdFonts/JetBrainsMonoNerdFont-Regular.ttf";

  home-manager = {
    useGlobalPkgs = true;
    config = {
      imports = [
        "${self}/profiles/home-manager/neovim.nix"
        "${self}/profiles/home-manager/ssh.nix"
        "${self}/profiles/home-manager/shell/common.nix"
      ];

      programs.bash.enable = true;

      home.stateVersion = "24.05";
    };
  };
}
