{
  config,
  lib,
  pkgs,
  ...
}:

let
  isWayland =
    config.programs.sway.enable
    || config.programs.hyprland.enable
    || config.programs.niri.enable
    || config.services.desktopManager.gnome.enable
    || config.services.desktopManager.plasma6.enable
    || config.services.desktopManager.cosmic.enable;

  myEmacs = if isWayland then pkgs.emacs-pgtk else pkgs.emacs;
in
{
  fonts.packages = [ pkgs.emacs-all-the-icons-fonts ];

  programs.neovim.defaultEditor = false;

  services.emacs = {
    enable = true;
    install = true;
    defaultEditor = true;
    package = (
      (pkgs.emacsPackagesFor myEmacs).emacsWithPackages (epkgs: [
        epkgs.vterm
        epkgs.pdf-tools
        epkgs.org-roam
      ])
    );
  };

  environment.systemPackages = with pkgs; [
    binutils
    fd
    gnutls
    go
    hugo # ox-hugo
    imagemagick
    libtool # for vterm
    mlocate
    nixfmt-rfc-style
    (ripgrep.override { withPCRE2 = true; })
    sqlite # org-roam
    zstd

    black
    cargo
    ccls # C/C++ LSP support
    clang-tools # clang-format as a C/C++ formatter
    cljfmt
    cmake
    editorconfig-core-c
    dockfmt
    gcc
    gnumake
    graphviz
    html-tidy
    isort
    jdk
    julia
    libxml2
    nil # nix LSP
    nodejs
    nodePackages.stylelint
    nodePackages.js-beautify
    pandoc
    pipenv
    pyright
    racket
    rustc
    rust-analyzer
    shellcheck
    shfmt
    texlive.combined.scheme-full
    python3Packages.pygments # minted syntax highlighting in latex
  ];
}
