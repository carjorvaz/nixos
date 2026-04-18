{
  buildGoModule,
  exiftool,
  fetchFromGitHub,
  fetchurl,
  ffmpeg-headless,
  lib,
  path,
  replaceVars,
  stdenv,
}:
let
  version = "8.0.1";

  commonMeta = with lib; {
    homepage = "https://apps.nextcloud.com/apps/memories";
    changelog = "https://github.com/pulsejet/memories/blob/v${version}/CHANGELOG.md";
    license = licenses.agpl3Only;
    maintainers = with maintainers; [ SuperSandro2000 ];
    platforms = platforms.linux;
  };

  go-vod = buildGoModule rec {
    pname = "go-vod";
    inherit version;

    src = fetchFromGitHub {
      owner = "pulsejet";
      repo = "memories";
      tag = "v${version}";
      hash = "sha256-t/DiGJzSey9YpV5GkepKSGjr5gXc9KWDBtSY5UPRlEU=";
    };

    sourceRoot = "${src.name}/go-vod";
    vendorHash = null;

    meta = commonMeta // {
      description = "Extremely minimal on-demand video transcoding server in go";
      mainProgram = "go-vod";
    };
  };
in
stdenv.mkDerivation rec {
  pname = "nextcloud-app-memories";
  inherit version;

  src = fetchurl {
    url = "https://github.com/pulsejet/memories/releases/download/v${version}/memories.tar.gz";
    hash = "sha256-B+O78qjBQbmMnFAvH/5a+YBive+rkBG9AKTX7G3qNR0=";
  };

  patches = [
    (replaceVars (path + "/pkgs/servers/nextcloud/packages/apps/memories-paths.diff") {
      exiftool = lib.getExe exiftool;
      ffmpeg = lib.getExe ffmpeg-headless;
      ffprobe = lib.getExe' ffmpeg-headless "ffprobe";
      go-vod = lib.getExe go-vod;
    })
  ];

  postPatch = ''
    rm appinfo/signature.json
    rm -rf bin-ext/

    sed -i 's/EXIFTOOL_VER = .*/EXIFTOOL_VER = @;/' lib/Service/BinExt.php
    substituteInPlace lib/Service/BinExt.php \
      --replace-fail "EXIFTOOL_VER = @" "EXIFTOOL_VER = '${exiftool.version}'"
  '';

  installPhase = ''
    mkdir -p $out
    cp -r ./* $out/
  '';

  meta = commonMeta // {
    description = "Fast, modern and advanced photo management suite";
    longDescription = ''
      All settings related to required packages and installed programs are hardcoded in program code and cannot be changed.
    '';
  };
}
