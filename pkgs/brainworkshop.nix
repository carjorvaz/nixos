{ lib, stdenv, fetchFromGitHub, python3Packages, ffmpeg-full, fetchPypi, unzip
, libGL, libGLU, xorg, glibc, gtk2-x11, gdk-pixbuf, fontconfig, freetype, openal
, libpulseaudio }:

let
  customPyglet = python3Packages.buildPythonPackage rec {
    version = "2.0.10";
    pname = "pyglet";

    src = fetchPypi  {
      inherit pname version;
      hash = "sha256-JCvrGzvWfFvr3+W6EexWtpathrUMbn8qMX+NeDJWuck=";
      extension = "zip";
    };

    postPatch = let ext = stdenv.hostPlatform.extensions.sharedLibrary;
    in ''
      cat > pyglet/lib.py <<EOF
      import ctypes
      def load_library(*names, **kwargs):
          for name in names:
              path = None
              if name == 'GL':
                  path = '${libGL}/lib/libGL${ext}'
              elif name == 'EGL':
                  path = '${libGL}/lib/libEGL${ext}'
              elif name == 'GLU':
                  path = '${libGLU}/lib/libGLU${ext}'
              elif name == 'c':
                  path = '${glibc}/lib/libc${ext}.6'
              elif name == 'X11':
                  path = '${xorg.libX11}/lib/libX11${ext}'
              elif name == 'gdk-x11-2.0':
                  path = '${gtk2-x11}/lib/libgdk-x11-2.0${ext}'
              elif name == 'gdk_pixbuf-2.0':
                  path = '${gdk-pixbuf}/lib/libgdk_pixbuf-2.0${ext}'
              elif name == 'Xext':
                  path = '${xorg.libXext}/lib/libXext${ext}'
              elif name == 'fontconfig':
                  path = '${fontconfig.lib}/lib/libfontconfig${ext}'
              elif name == 'freetype':
                  path = '${freetype}/lib/libfreetype${ext}'
              elif name[0:2] == 'av' or name[0:2] == 'sw':
                  path = '${lib.getLib ffmpeg-full}/lib/lib' + name + '${ext}'
              elif name == 'openal':
                  path = '${openal}/lib/libopenal${ext}'
              elif name == 'pulse':
                  path = '${libpulseaudio}/lib/libpulse${ext}'
              elif name == 'Xi':
                  path = '${xorg.libXi}/lib/libXi${ext}'
              elif name == 'Xinerama':
                  path = '${xorg.libXinerama}/lib/libXinerama${ext}'
              elif name == 'Xxf86vm':
                  path = '${xorg.libXxf86vm}/lib/libXxf86vm${ext}'
              if path is not None:
                  return ctypes.cdll.LoadLibrary(path)
          raise Exception("Could not load library {}".format(names))
      EOF
    '';

    nativeBuildInputs = [ unzip ];

    doCheck = false;
    preCheck = ''
      export PYGLET_HEADLESS=True
    '';

    pythonImportsCheck = [ "pyglet" ];

    meta = with lib; {
      homepage = "http://www.pyglet.org/";
      description = "A cross-platform windowing and multimedia library";
      license = licenses.bsd3;
      platforms = platforms.mesaPlatforms;
    };
  };
in python3Packages.buildPythonApplication {
  pname = "brainworkshop";
  version = "5.0.3";

  src = fetchFromGitHub {
    owner = "brain-workshop";
    repo = "brainworkshop";
    rev = "31b125162c63c111358ead73d9c02905363c8c1c";
    sha256 = "sha256-w3q9CDrHev5s0e4DI90WI1JzyvGzu0Oj1YSC8K9HKL4=";
  };

  propagatedBuildInputs = [ customPyglet ffmpeg-full ];

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
    description =
      "A free open-source version of the Dual N-Back mental exercise";
    homepage = "http://brainworkshop.sourceforge.net/";
    license = lib.licenses.gpl2Plus;
  };
}
