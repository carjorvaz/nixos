{
  lib,
  fetchFromGitHub,
  python3Packages,
  ffmpeg-full,
}:

python3Packages.buildPythonApplication {
  pname = "brainworkshop";
  version = "5.0.3";

  src = fetchFromGitHub {
    owner = "brain-workshop";
    repo = "brainworkshop";
    rev = "31b125162c63c111358ead73d9c02905363c8c1c";
    sha256 = "sha256-w3q9CDrHev5s0e4DI90WI1JzyvGzu0Oj1YSC8K9HKL4=";
  };

  propagatedBuildInputs = [
    python3Packages.pyglet
    ffmpeg-full
  ];

  format = "other";

  # TODO .desktop file
  installPhase = ''
    mkdir -p $out/bin
    cp $src/brainworkshop.py $out/bin/brainworkshop
    chmod +x $out/bin/brainworkshop
    cp -r $src/data $out/bin/data
    cp -r $src/res $out/bin/res
    cp -r $src/tools $out/bin/tools
  '';

  meta = {
    description = "A free open-source version of the Dual N-Back mental exercise";
    homepage = "http://brainworkshop.sourceforge.net/";
    license = lib.licenses.gpl2Plus;
  };
}
