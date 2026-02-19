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

  services.emacs = {
    enable = true;
    install = true;
    package = (
      (pkgs.emacsPackagesFor myEmacs).emacsWithPackages (epkgs: [
        epkgs.vterm
        epkgs.pdf-tools
        epkgs.org-roam
        epkgs.treesit-grammars.with-all-grammars
      ])
    );
  };

  environment.systemPackages = with pkgs; [
    binutils
    fd
    gnutls
    hugo # ox-hugo
    imagemagick
    nixfmt
    (ripgrep.override { withPCRE2 = true; })
    sqlite # org-roam
    zstd

    black
    cargo
    editorconfig-core-c
    dockfmt
    graphviz
    html-tidy
    isort
    julia-bin # Use binary to avoid GMP/GCC15 build failure
    nil # nix LSP
    nodePackages.bash-language-server # sh +lsp
    nodePackages.dockerfile-language-server-nodejs # docker +lsp
    nodePackages.typescript-language-server # javascript +lsp
    nodePackages.yaml-language-server # yaml +lsp
    nodejs
    nodePackages.stylelint
    nodePackages.js-beautify
    pandoc
    pyright
    rustc
    rust-analyzer
    shellcheck
    shfmt
    texlab # latex +lsp
    texlive.combined.scheme-full
    vscode-langservers-extracted # json/html/css +lsp
    python3Packages.pygments # minted syntax highlighting in latex
  ];
}
