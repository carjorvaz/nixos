{ appimageTools, fetchurl }:
# TODO/maybe:
# - use makeDesktopItem to create a proper desktop entry
let
  version = "2.3.0-beta2";
in
appimageTools.wrapType2 {
  inherit version;
  pname = "orca-slicer-appimage";
  src = fetchurl {
    url = "https://github.com/SoftFever/OrcaSlicer/releases/download/v${version}/OrcaSlicer_Linux_AppImage_V${version}.AppImage";
    hash = "sha256-c0Lryyv9uhdbpESI3FDv7rBNP7eGpZXicormzYf2u5I=";
  };
  extraPkgs =
    pkgs: with pkgs; [
      glib-networking
      webkitgtk_4_0
    ];
}
