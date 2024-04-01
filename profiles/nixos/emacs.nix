{ config, lib, pkgs, ... }:

{
  services.emacs = {
    enable = true;
    package = ((pkgs.emacsPackagesFor pkgs.emacs29-pgtk).emacsWithPackages
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
    nixfmt
    zstd
    imagemagick

    ccls # C/C++ LSP support
    clang-tools # clang-format as a C/C++ formatter
    shellcheck
    pandoc
    cmake
    gnumake
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
