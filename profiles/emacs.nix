{ config, lib, pkgs, ... }:

{
  services.emacs = {
    enable = true;
    package = ((pkgs.emacsPackagesFor pkgs.emacs-gtk).emacsWithPackages
      (epkgs: [ epkgs.vterm epkgs.pdf-tools ]));
  };

  environment.systemPackages = with pkgs; [
    mlocate
    ripgrep
    fd
    go
    hugo # ox-hugo
    sqlite # org-roam
    nixfmt

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
  ];
}
