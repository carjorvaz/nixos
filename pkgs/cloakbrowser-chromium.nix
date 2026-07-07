{
  lib,
  stdenvNoCC,
  fetchurl,
  runtimeShell,
}:

let
  platformInfo =
    {
      aarch64-darwin = {
        platformTag = "darwin-arm64";
        version = "145.0.7632.109.2";
        hash = "sha256-UFWCqhvTlxxXf3Dgy74BZDFwK9tpNSmr/ZQ7W9kSDBw=";
      };
    }
    .${stdenvNoCC.hostPlatform.system} or {
      platformTag = "unsupported";
      version = "0";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };

  cloakbrowserBinaryLicense = {
    shortName = "cloakbrowser-binary";
    fullName = "CloakBrowser Binary License";
    url = "https://github.com/CloakHQ/CloakBrowser/blob/main/BINARY-LICENSE.md";
    free = false;
    redistributable = false;
  };
in
stdenvNoCC.mkDerivation {
  pname = "cloakbrowser-chromium";
  inherit (platformInfo) version;

  src = fetchurl {
    url = "https://cloakbrowser.dev/chromium-v${platformInfo.version}/cloakbrowser-${platformInfo.platformTag}.tar.gz";
    inherit (platformInfo) hash;
  };

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications" "$out/bin"
    tar -xzf "$src" -C "$out/Applications"

    printf '%s\n' \
      '#!${runtimeShell}' \
      "exec \"$out/Applications/Chromium.app/Contents/MacOS/Chromium\" \"\$@\"" \
      > "$out/bin/cloakbrowser-chrome"
    chmod +x "$out/bin/cloakbrowser-chrome"

    runHook postInstall
  '';

  meta = {
    description = "Official CloakBrowser patched Chromium binary";
    homepage = "https://github.com/CloakHQ/CloakBrowser";
    license = cloakbrowserBinaryLicense;
    mainProgram = "cloakbrowser-chrome";
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
