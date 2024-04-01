{ appimageTools, fetchurl }:

# TODO/maybe:
# - use makeDesktopItem to create a proper desktop entry
# - create package from source instead of appimage
appimageTools.wrapType2 {
  name = "qidi-slicer";
  src = let version = "1.1.1";
  in fetchurl {
    url =
      "https://github.com/QIDITECH/QIDISlicer/releases/download/V${version}/QIDISlicer_${version}_Linux.AppImage";
    hash = "sha256-QaNdpf2Zh6+E3YhhyOifYEIXnQet5GK4gpq9R0jskmA=";
  };
  extraPkgs = pkgs: with pkgs; [ glib-networking webkitgtk ];
}
