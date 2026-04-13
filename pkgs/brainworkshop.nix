{
  lib,
  stdenv,
  fetchFromGitHub,
  python3,
  ffmpeg-full,
  harfbuzz,
  writeText,
  copyDesktopItems,
  makeDesktopItem,
  desktopToDarwinBundle,
  makeWrapper,
}:

let
  # nixpkgs's pyglet darwin postPatch rewrites lib.py but only wires up
  # avutil (not avcodec/avformat/swresample/swscale → music silently
  # disabled) and points frameworks at apple-sdk stubs that dyld can't load
  # at runtime (→ OpenGL import crash). Replace with a complete version.
  # Closure cost is zero: ffmpeg-full and harfbuzz are already in pyglet's
  # runtime deps via the partial upstream patch.
  pygletLibPy = writeText "pyglet-lib-darwin.py" ''
    import os
    import ctypes


    def load_library(*names, **kwargs):
        framework = kwargs.get('framework')
        if framework is not None:
            return ctypes.cdll.LoadLibrary(
                '/System/Library/Frameworks/{f}.framework/{f}'.format(f=framework)
            )

        names = kwargs.get('darwin', names)
        if not isinstance(names, tuple):
            names = (names,)

        for name in names:
            if name == 'libharfbuzz.0.dylib':
                return ctypes.cdll.LoadLibrary('${harfbuzz}/lib/' + name)
            base = name.split('.')[0]
            if base[:2] in ('av', 'sw'):
                # Try the versioned name first (e.g. libavutil.60.dylib), then
                # fall back to the unversioned symlink (libavutil.dylib) so an
                # older pyglet that doesn't know the current soversion still works.
                for candidate in [
                    '${ffmpeg-full.lib}/lib/lib' + name + '.dylib',
                    '${ffmpeg-full.lib}/lib/lib' + base + '.dylib',
                ]:
                    if os.path.exists(candidate):
                        return ctypes.cdll.LoadLibrary(candidate)

        raise ImportError('Could not load library {}'.format(names))
  '';

  pyglet =
    if stdenv.hostPlatform.isDarwin then
      python3.pkgs.pyglet.overridePythonAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          install -m 0644 ${pygletLibPy} pyglet/lib.py
        '';
      })
    else
      python3.pkgs.pyglet;

  pythonEnv = python3.withPackages (_: [ pyglet ]);
in
stdenv.mkDerivation (finalAttrs: {
  pname = "brainworkshop";
  version = "5.0.3-unstable-2025-04-22";

  src = fetchFromGitHub {
    owner = "brain-workshop";
    repo = "brainworkshop";
    rev = "3476f724eb623b6e39605bd7a7e3df245787e73a";
    hash = "sha256-oCiNX+ewZ5Inc9mGTYY0PamCpjo7eMbCHCsFYmvL5eE=";
  };

  dontBuild = true;

  nativeBuildInputs =
    [
      makeWrapper
      copyDesktopItems
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [ desktopToDarwinBundle ];

  desktopItems = [
    (makeDesktopItem {
      name = "brainworkshop";
      exec = "brainworkshop";
      icon = "brainworkshop";
      desktopName = "Brain Workshop";
      comment = finalAttrs.meta.description;
      categories = [ "Education" ];
      terminal = false;
    })
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/brainworkshop
    cp brainworkshop.py $out/share/brainworkshop/
    cp -r res $out/share/brainworkshop/

    mkdir -p $out/bin
    makeWrapper ${lib.getExe pythonEnv} $out/bin/brainworkshop \
      --add-flags "$out/share/brainworkshop/brainworkshop.py"

    mkdir -p $out/share/icons/hicolor/48x48/apps
    cp res/misc/brain/brain.png $out/share/icons/hicolor/48x48/apps/brainworkshop.png

    runHook postInstall
  '';

  # write-darwin-bundle (from desktopToDarwinBundle) bakes the desktop file's
  # Name into CFBundleIdentifier as `org.nixos.<Name>`, producing
  # `org.nixos.Brain Workshop` — bundle IDs cannot contain spaces. Rewrite
  # the plist after fixupPhase to a conformant identifier.
  postFixup = lib.optionalString stdenv.hostPlatform.isDarwin ''
    plist="$out/Applications/Brain Workshop.app/Contents/Info.plist"
    substituteInPlace "$plist" \
      --replace-fail \
        "<string>org.nixos.Brain Workshop</string>" \
        "<string>org.nixos.brainworkshop</string>"
  '';

  meta = {
    description = "A free open-source version of the Dual N-Back mental exercise";
    homepage = "http://brainworkshop.sourceforge.net/";
    license = lib.licenses.gpl2Plus;
    mainProgram = "brainworkshop";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
})
