{ appimageTools, fetchurl }:

# TODO/maybe:
# - use makeDesktopItem to create a proper desktop entry
# - create package from source instead of appimage
appimageTools.wrapType2 {
  name = "orca-slicer";
  src = let version = "2.0.0-beta";
  in fetchurl {
    url =
      "https://github.com/SoftFever/OrcaSlicer/releases/download/v${version}/OrcaSlicer_Linux_V${version}.AppImage";
    hash = "sha256-KsHPGlIUhaKjGv9BfAlYs4eWmFMcqclYvm2XwGRnbeA=";
  };
  extraPkgs = pkgs: with pkgs; [ glib-networking webkitgtk ];
}
