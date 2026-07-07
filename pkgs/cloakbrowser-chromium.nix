{
  lib,
  stdenvNoCC,
  fetchurl,
  runtimeShell,
}:

let
  sources = {
    aarch64-darwin = {
      platformTag = "darwin-arm64";
      version = "145.0.7632.109.2";
      hash = "sha256-UFWCqhvTlxxXf3Dgy74BZDFwK9tpNSmr/ZQ7W9kSDBw=";
    };
  };

  source = sources.${stdenvNoCC.hostPlatform.system} or null;
  isSupported = source != null;
  version = if isSupported then source.version else "0";
  archiveName =
    if isSupported then "cloakbrowser-${source.platformTag}.tar.gz" else "unsupported.tar.gz";

  cloakbrowserBinaryLicense = {
    shortName = "cloakbrowser-binary";
    fullName = "CloakBrowser Binary License";
    url = "https://github.com/CloakHQ/CloakBrowser/blob/main/BINARY-LICENSE.md";
    free = false;
    redistributable = false;
  };

  appExecutable = "Applications/Chromium.app/Contents/MacOS/Chromium";
in
stdenvNoCC.mkDerivation {
  pname = "cloakbrowser-chromium";
  inherit version;

  src =
    if isSupported then
      fetchurl {
        urls = [
          "https://cloakbrowser.dev/chromium-v${version}/${archiveName}"
          "https://github.com/CloakHQ/cloakbrowser/releases/download/chromium-v${version}/${archiveName}"
        ];
        inherit (source) hash;
      }
    else
      null;

  dontUnpack = true;

  installPhase =
    if isSupported then
      ''
        runHook preInstall

        mkdir -p "$out/Applications" "$out/bin"
        tar -xzf "$src" -C "$out/Applications"

        printf '%s\n' \
          '#!${runtimeShell}' \
          "exec \"$out/${appExecutable}\" \"\$@\"" \
          > "$out/bin/cloakbrowser-chrome"
        chmod +x "$out/bin/cloakbrowser-chrome"

        runHook postInstall
      ''
    else
      ''
        echo '${stdenvNoCC.hostPlatform.system} is not supported by cloakbrowser-chromium' >&2
        exit 1
      '';

  passthru = {
    inherit appExecutable cloakbrowserBinaryLicense sources;
    platformTag = if isSupported then source.platformTag else null;

  };

  meta = {
    description = "Official CloakBrowser patched Chromium binary";
    homepage = "https://github.com/CloakHQ/CloakBrowser";
    license = cloakbrowserBinaryLicense;
    mainProgram = "cloakbrowser-chrome";
    platforms = builtins.attrNames sources;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
