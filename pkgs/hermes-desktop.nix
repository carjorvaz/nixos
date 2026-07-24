{
  buildNpmPackage,
  electron,
  inputs,
  lib,
  makeWrapper,
  pkgs,
  stdenv,
  hermesAgent ? inputs.hermes-agent.packages.${stdenv.hostPlatform.system}.default,
  hermesCliPath ? lib.getExe hermesAgent,
}:

let
  hermesNpmLib = hermesAgent.passthru.hermesNpmLib;
  npm = hermesNpmLib.mkNpmPassthru {
    dirs = [
      "apps/desktop"
      "apps/shared"
    ];
  };

  packageJson = builtins.fromJSON (builtins.readFile (npm.src + "/apps/desktop/package.json"));
  macBuild = packageJson.build.mac or { };
  macExtendInfo = macBuild.extendInfo or { };
  desktopMetadataVersion = packageJson.version;
  # Treat the Python Agent package as the canonical Hermes release version.
  # Upstream Desktop metadata has lagged the Agent release, and immutable Nix
  # builds cannot fall back to a mutable ~/.hermes source checkout for version
  # resolution like the upstream installer path can.
  version = lib.getVersion hermesAgent;
  electronHeaders = pkgs.fetchurl {
    url = "https://artifacts.electronjs.org/headers/dist/v${electron.version}/node-v${electron.version}-headers.tar.gz";
    hash = "sha256-0nUJBQDEikyYntZwq+ycH32mzEQtQmz3ICz9eeTMpJk=";
  };

  nodePtyPlatform =
    if stdenv.hostPlatform.isDarwin then
      "darwin"
    else if stdenv.hostPlatform.isLinux then
      "linux"
    else
      throw "hermes-desktop: unsupported host platform for node-pty staging";
  nodePtyArch =
    if stdenv.hostPlatform.isAarch64 then
      "arm64"
    else if stdenv.hostPlatform.isx86_64 then
      "x64"
    else
      throw "hermes-desktop: unsupported host architecture for node-pty staging";
  appName = packageJson.build.productName or "Hermes";
  appExecutableName = macExtendInfo.CFBundleExecutable or appName;
  appBundleName = "${appName}.app";
  appBundleId = packageJson.build.appId or "com.nousresearch.hermes";
  appCategory = macBuild.category or "public.app-category.developer-tools";
  appInfoPlist = pkgs.writeText "hermes-desktop-Info.plist" (
    lib.generators.toPlist { escape = true; } (
      {
        CFBundleDevelopmentRegion = "en";
        CFBundleDisplayName = macExtendInfo.CFBundleDisplayName or appName;
        CFBundleExecutable = appExecutableName;
        CFBundleIconFile = appName;
        CFBundleIdentifier = appBundleId;
        CFBundleInfoDictionaryVersion = "6.0";
        CFBundleName = macExtendInfo.CFBundleName or appName;
        CFBundlePackageType = "APPL";
        CFBundleShortVersionString = version;
        CFBundleVersion = version;
        LSApplicationCategoryType = appCategory;
        NSHighResolutionCapable = true;
      }
      // lib.optionalAttrs (macExtendInfo ? NSAudioCaptureUsageDescription) {
        inherit (macExtendInfo) NSAudioCaptureUsageDescription;
      }
      // lib.optionalAttrs (macExtendInfo ? NSMicrophoneUsageDescription) {
        inherit (macExtendInfo) NSMicrophoneUsageDescription;
      }
    )
  );

  renderer = buildNpmPackage (
    npm
    // {
      pname = "hermes-desktop-renderer";
      inherit version;

      doCheck = true;

      buildPhase = ''
        runHook preBuild

        mkdir -p apps/desktop/build
        patchShebangs .

        pushd apps/desktop
        npm exec tsc -b
        npm exec vite build
        node scripts/bundle-electron-main.mjs

        mkdir -p "$TMPDIR/electron-headers"
        tar -xzf ${electronHeaders} -C "$TMPDIR/electron-headers" --strip-components=1
        npm rebuild node-pty \
          --build-from-source \
          --runtime=electron \
          --target=${electron.version} \
          --nodedir="$TMPDIR/electron-headers" \
          --disturl="" \
          --offline
        node scripts/stage-native-deps.mjs ${nodePtyPlatform} ${nodePtyArch}
        popd

        runHook postBuild
      '';

      checkPhase = ''
        runHook preCheck

        pushd apps/desktop
        npm run postbuild
        test -f dist/node_modules/node-pty/build/Release/pty.node
        popd

        runHook postCheck
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out
        cp -r apps/desktop/dist $out/
        echo '{"schemaVersion":1,"commit":"nix","branch":"nix","dirty":false,"source":"nix"}' > $out/install-stamp.json
        cp apps/desktop/package.json $out/
        substituteInPlace $out/package.json \
          --replace-fail '"version": "${desktopMetadataVersion}"' '"version": "${version}"'

        runHook postInstall
      '';
    }
  );
in
stdenv.mkDerivation {
  pname = "hermes-desktop";
  inherit version;

  dontUnpack = true;
  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/hermes-desktop $out/bin
    cp -r ${renderer}/* $out/share/hermes-desktop/
    substituteInPlace $out/share/hermes-desktop/dist/electron-main.mjs \
      --replace-fail "process.resourcesPath" "'$out/share/hermes-desktop'"


    makeHermesDesktopWrapper() {
      makeWrapper ${lib.getExe electron} "$1" \
        --add-flags "$out/share/hermes-desktop" \
        --set HERMES_DESKTOP_HERMES ${lib.escapeShellArg hermesCliPath} \
        --set HERMES_DESKTOP_NATIVE_SUDO 1 \
        --set ELECTRON_IS_DEV 0
    }

    makeHermesDesktopWrapper "$out/bin/hermes-desktop"

    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      app="$out/Applications/${appBundleName}"
      mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

      cp ${appInfoPlist} "$app/Contents/Info.plist"
      printf 'APPL????' > "$app/Contents/PkgInfo"
      makeHermesDesktopWrapper "$app/Contents/MacOS/${appExecutableName}"

      app_icon="$out/share/hermes-desktop/dist/apple-touch-icon.png"
      cp "$app_icon" "$app/Contents/Resources/${appName}.png"

      iconset="$TMPDIR/hermes-desktop.iconset"
      mkdir -p "$iconset"
      for size in 16 32 128 256 512; do
        /usr/bin/sips -z "$size" "$size" \
          "$app_icon" \
          --out "$iconset/icon_''${size}x''${size}.png" >/dev/null
        double_size=$((size * 2))
        /usr/bin/sips -z "$double_size" "$double_size" \
          "$app_icon" \
          --out "$iconset/icon_''${size}x''${size}@2x.png" >/dev/null
      done
      /usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/${appName}.icns"
    ''}

    runHook postInstall
  '';

  passthru = {
    inherit renderer hermesCliPath;
    inherit (renderer.passthru) packageJsonPath;
  };

  meta = with lib; {
    description = "Native Electron desktop shell for Hermes Agent, with Nix-staged node-pty support";
    homepage = "https://github.com/NousResearch/hermes-agent";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "hermes-desktop";
  };
}
