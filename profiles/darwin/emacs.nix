{ pkgs, ... }:

let
  emacsLiquidGlassIcon = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/leaferiksen/emacs-liquid-glass-icon/1d2cba63900f1e9d67914774c38d74b19601b630/Resources/Emacs.icns";
    sha256 = "1saxgm6rxl0q4mp6gchwwj9gcgicr60bj4gx2jlwaipfa7kfgv9p";
  };

  emacsLiquidGlassAssets = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/leaferiksen/emacs-liquid-glass-icon/1d2cba63900f1e9d67914774c38d74b19601b630/Resources/Assets.car";
    sha256 = "08bzygf6ihsglj81x9g143ccwyv68n1p9ss4pjmlsaagji3jzlqd";
  };
in
{
  environment.systemPackages = with pkgs; [
    # Emacs - https://github.com/leaferiksen/emacs-liquid-glass-icon
    (let
      myEmacs = (emacsPackagesFor emacs).emacsWithPackages (epkgs: [
        epkgs.vterm
        epkgs.pdf-tools
        epkgs.org-roam
        epkgs.treesit-grammars.with-all-grammars
      ]);
    in
      pkgs.symlinkJoin {
        name = "emacs-liquid-glass";
        paths = [ myEmacs ];
        postBuild = ''
          rm $out/Applications/Emacs.app/Contents/Resources/Emacs.icns
          cp ${emacsLiquidGlassIcon} $out/Applications/Emacs.app/Contents/Resources/Emacs.icns
          cp ${emacsLiquidGlassAssets} $out/Applications/Emacs.app/Contents/Resources/Assets.car
        '';
      })

    # Runtime tools (LSPs, formatters, etc.)
    nixfmt
    cmake
    ccls
    coreutils-prefixed # gls for dired on macOS
    nodejs
    clang-tools
    fontconfig # fc-list for Doom's font checks
    graphviz
    black
    shellcheck
    shfmt
    nil # nix LSP
    nodePackages.js-beautify
    nodePackages.stylelint
    pandoc # markdown preview/export
    pyright
    python3Packages.pygments
    rust-analyzer
    texlab
    texlive.combined.scheme-full # Quite big, around 20GB. Remove if I'm running out of space.
    sqlite # org-roam
    zstd # undo-fu-session compression
    imagemagick
    (ripgrep.override { withPCRE2 = true; })
  ];
}
