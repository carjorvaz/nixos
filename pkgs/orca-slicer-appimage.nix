{ appimageTools, fetchurl }:
# TODO/maybe:
# - use makeDesktopItem to create a proper desktop entry
let
  version = "2.2.0";
in
appimageTools.wrapType2 {
  inherit version;
  pname = "orca-slicer-appimage";
  src = fetchurl {
    url = "https://github.com/SoftFever/OrcaSlicer/releases/download/v${version}/OrcaSlicer_Linux_V${version}.AppImage";
    hash = "sha256-3uqA3PXTrrOE0l8ziRAtmQ07gBFB+1Zx3S6JhmOPrZ8=";
  };
  extraPkgs =
    pkgs: with pkgs; [
      glib-networking
      webkitgtk_4_0
    ];
}
