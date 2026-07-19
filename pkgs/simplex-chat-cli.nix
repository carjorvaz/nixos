{
  autoPatchelfHook,
  fetchurl,
  gmp,
  lib,
  openssl,
  stdenv,
  zlib,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "simplex-chat-cli";
  version = "6.5.6";

  src = fetchurl {
    url = "https://github.com/simplex-chat/simplex-chat/releases/download/v${finalAttrs.version}/simplex-chat-ubuntu-22_04-x86_64";
    hash = "sha256-6qMQZhajms3KdbIxLVbkG6u268pUIEyUOpkuxLlGEVQ=";
  };

  dontUnpack = true;
  nativeBuildInputs = [ autoPatchelfHook ];
  buildInputs = [
    gmp
    openssl
    zlib
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/simplex-chat"
    runHook postInstall
  '';

  meta = {
    description = "Terminal client and WebSocket daemon for SimpleX Chat";
    homepage = "https://simplex.chat/";
    changelog = "https://github.com/simplex-chat/simplex-chat/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.agpl3Only;
    mainProgram = "simplex-chat";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
