{ appimageTools, fetchurl }:

# TODO/maybe:
# - use makeDesktopItem to create a proper desktop entry
appimageTools.wrapType2 {
  name = "orca-slicer-appimage";
  src =
    let
      version = "2.1.1";
    in
    fetchurl {
      url = "https://github.com/SoftFever/OrcaSlicer/releases/download/v${version}/OrcaSlicer_Linux_V${version}.AppImage";
      hash = "sha256-kvM1rBGEJhjRqQt3a8+I0o4ahB1Uc9qB+4PzhYoNQdM=";
    };

  extraPkgs =
    pkgs: with pkgs; [
      glib-networking
      webkitgtk
    ];
}
