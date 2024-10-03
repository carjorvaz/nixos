{ appimageTools, fetchurl }:

# TODO/maybe:
# - use makeDesktopItem to create a proper desktop entry
appimageTools.wrapType2 {
  name = "orca-slicer-appimage";
  src =
    let
      version = "2.2.0-beta";
    in
    fetchurl {
      url = "https://github.com/SoftFever/OrcaSlicer/releases/download/v${version}/OrcaSlicer_Linux_Ubuntu2404_V${version}.AppImage";
      hash = "sha256-jTRfcs84MDbiM6G/sYM9eV8tEGINa1irPGmuFfj+tTM=";
    };

  extraPkgs =
    pkgs: with pkgs; [
      glib-networking
      webkitgtk_4_1
    ];
}
