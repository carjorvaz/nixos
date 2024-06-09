{ appimageTools, fetchurl }:

# TODO/maybe:
# - use makeDesktopItem to create a proper desktop entry
# - create package from source instead of appimage (like prusa-slicer)
appimageTools.wrapType2 {
  name = "orca-slicer";
  src =
    let
      version = "2.0.0";
    in
    fetchurl {
      url = "https://github.com/SoftFever/OrcaSlicer/releases/download/v${version}/OrcaSlicer_Linux_V${version}.AppImage";
      hash = "sha256-PcCsqF1RKdSrbdp1jCF0n5Mu30EniaBEuJNw3XdPhO4=";
    };
  extraPkgs =
    pkgs: with pkgs; [
      glib-networking
      webkitgtk
    ];
}
