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
    folder = "apps/desktop";
    attr = "desktop";
    pname = "hermes-desktop";
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
  nodePtyPlatform =
    if stdenv.hostPlatform.isDarwin then
      "darwin"
    else if stdenv.hostPlatform.isLinux then
      "linux"
    else
      stdenv.hostPlatform.parsed.kernel.name;
  nodePtyArch = if stdenv.hostPlatform.isAarch64 then "arm64" else "x64";
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

      doCheck = false;
      makeCacheWritable = true;

      buildPhase = ''
        runHook preBuild

        # write-build-stamp.cjs replacement. Packaged Electron reads this from
        # resources/install-stamp.json; the Nix launcher keeps it in the app tree
        # for the same runtime code path and for deterministic metadata.
        mkdir -p apps/desktop/build
        echo '{"schemaVersion":1,"commit":"nix","branch":"nix","dirty":false,"source":"nix"}' > apps/desktop/build/install-stamp.json

        # Upstream desktop packaging stages node-pty for electron-builder via
        # apps/desktop/scripts/stage-native-deps.cjs. The Nix desktop package
        # launches the app directory directly with nixpkgs' Electron instead of
        # running electron-builder, so we must still perform that staging step.
        cd apps/desktop
        node scripts/stage-native-deps.cjs

        # Build renderer assets. Keep upstream's Nix choice to skip tsc here:
        # Vite transpiles TS and avoids non-shipped test type churn.
        node ../../node_modules/vite/bin/vite.js build --outDir dist
        cd ../..

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mkdir -p $out
        cp -r apps/desktop/dist $out/
        cp -r apps/desktop/electron $out/
        cp -r apps/desktop/build $out/
        cp apps/desktop/package.json $out/
        # Align Electron's app.getVersion() with the canonical Hermes Agent
        # package version exposed by the Nix wrapper.
        substituteInPlace $out/package.json \
          --replace-fail '"version": "${desktopMetadataVersion}"' '"version": "${version}"'

        # electron/main.cjs first does a bare require('node-pty'). In the
        # electron-builder bundle, that bare require fails and the code falls back
        # to process.resourcesPath/native-deps/node-pty. In this Nix package the
        # app is an unpacked directory launched by nixpkgs' Electron, so
        # process.resourcesPath belongs to Electron itself, not our app. Install
        # the staged native dependency under the app-local node_modules tree so
        # the normal Node resolver succeeds before the packaged-app fallback.
        mkdir -p $out/node_modules
        cp -R apps/desktop/build/native-deps/node-pty $out/node_modules/node-pty

        # Build-time sanity checks for the integrated terminal runtime payload.
        test -f $out/node_modules/node-pty/package.json
        test -f $out/node_modules/node-pty/lib/index.js
        test -n "$(find $out/node_modules/node-pty/prebuilds -name '*.node' -print -quit)"
        ${lib.optionalString stdenv.hostPlatform.isDarwin ''
          test -x $out/node_modules/node-pty/prebuilds/${nodePtyPlatform}-${nodePtyArch}/spawn-helper
        ''}

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
