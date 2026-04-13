{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    nixfmt
    cmake
    ccls
    nodejs
    clang-tools
    graphviz
    black
    shellcheck
    shfmt
    nil # nix LSP
    nodePackages.js-beautify
    nodePackages.stylelint
    pyright
    python3Packages.pygments
    rust-analyzer
    texlab
    texlive.combined.scheme-full # Quite big, around 20GB. Remove if I'm running out of space.
  ];

  homebrew = {
    taps = [ "d12frosted/emacs-plus" ];

    brews = [
      {
        # STATE: ln -s /usr/local/opt/emacs-plus/Emacs.app /Applications/Emacs.app
        name = "emacs-plus@31";
        args = [ "with-c9rgreen-sonoma-icon" ];
      }

      # Emacs dependencies
      "awk"
      "fribidi"
      "gdk-pixbuf"
      "giflib"
      "gnu-sed"
      "gnu-tar"
      "graphite2"
      "harfbuzz"
      "jansson"
      "jpeg"
      "pango"
      "librsvg"
      "make"
      "texinfo"
      "tree-sitter"
      "webp"
      "zlib"

      # Doom Emacs dependencies
      "coreutils"
      "gcc"
      "git"
      "grep"
      "libgccjit"
      "marked"
      "direnv"

      # pdf-tools dependencies
      "pkg-config"
      "autoconf"
      "automake"
      "poppler"

      # poppler dependencies
      "xorgproto"
      "libxau"
      "libxdmcp"
      "libxcb"
      "libx11"
      "libxext"
      "libxrender"
      "lzo"
      "pixman"
      "cairo"
      "xz"
      "nspr"
      "nss"

      # vterm dependencies
      "libtool"
      "libvterm"
    ];
  };
}
