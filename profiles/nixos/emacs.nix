{ config, lib, pkgs, ... }:

let
  isWayland = if config.programs.sway.enable || config.programs.hyprland.enable
  || config.services.xserver.desktopManager.gnome.enable then
    true
  else
    false;

  myEmacs = if isWayland then pkgs.emacs29-pgtk else pkgs.emacs29;
in {
  services.emacs = {
    enable = true;
    package = ((pkgs.emacsPackagesFor myEmacs).emacsWithPackages
      (epkgs: [ epkgs.vterm epkgs.pdf-tools epkgs.org-roam ]));
  };

  fonts.packages = [ pkgs.emacs-all-the-icons-fonts ];

  environment.systemPackages = with pkgs; [
    binutils
    mlocate
    (ripgrep.override { withPCRE2 = true; })
    gnutls
    fd
    go
    hugo # ox-hugo
    sqlite # org-roam
    nixfmt-rfc-style
    zstd
    imagemagick

    ccls # C/C++ LSP support
    clang-tools # clang-format as a C/C++ formatter
    shellcheck
    pandoc
    cmake
    gnumake
    nil # nix LSP
    nodejs
    graphviz
    black
    isort
    pipenv
    shfmt
    html-tidy
    nodePackages.stylelint
    nodePackages.js-beautify
    gcc
    pyright
    texlive.combined.scheme-full
  ];
}
