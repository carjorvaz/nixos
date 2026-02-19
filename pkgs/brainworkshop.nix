{
  lib,
  fetchFromGitHub,
  python3Packages,
  ffmpeg-full,
  copyDesktopItems,
  makeDesktopItem,
}:

python3Packages.buildPythonApplication {
  pname = "brainworkshop";
  version = "5.0.3";

  src = fetchFromGitHub {
    owner = "brain-workshop";
    repo = "brainworkshop";
    rev = "3476f724eb623b6e39605bd7a7e3df245787e73a";
    hash = "sha256-oCiNX+ewZ5Inc9mGTYY0PamCpjo7eMbCHCsFYmvL5eE=";
  };

  nativeBuildInputs = [ copyDesktopItems ];

  propagatedBuildInputs = [
    python3Packages.pyglet
    ffmpeg-full
  ];

  format = "other";

  desktopItems = [
    (makeDesktopItem {
      name = "brainworkshop";
      exec = "brainworkshop";
      icon = "brainworkshop";
      desktopName = "Brain Workshop";
      comment = "A free open-source version of the Dual N-Back mental exercise";
      categories = [ "Education" ];
      terminal = false;
    })
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp $src/brainworkshop.py $out/bin/brainworkshop
    chmod +x $out/bin/brainworkshop
    cp -r $src/data $out/bin/data
    cp -r $src/res $out/bin/res
    cp -r $src/tools $out/bin/tools

    # Install icon
    mkdir -p $out/share/icons/hicolor/256x256/apps
    cp $src/res/misc/brain/brain.png $out/share/icons/hicolor/256x256/apps/brainworkshop.png

    runHook postInstall
  '';

  meta = {
    description = "A free open-source version of the Dual N-Back mental exercise";
    homepage = "http://brainworkshop.sourceforge.net/";
    license = lib.licenses.gpl2Plus;
  };
}
