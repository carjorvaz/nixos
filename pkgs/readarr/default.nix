{ lib, stdenv, fetchurl, libmediainfo, sqlite, curl, makeWrapper, icu
, dotnet-runtime, openssl, nixosTests }:

let
  os = if stdenv.isDarwin then "osx" else "linux";
  arch = {
    x86_64-linux = "x64";
    aarch64-linux = "arm64";
    x86_64-darwin = "x64";
  }."${stdenv.hostPlatform.system}" or (throw
    "Unsupported system: ${stdenv.hostPlatform.system}");
  hash = {
    x64-linux_hash = "sha256-yXxZ7vmph8zHlhT9TvQV9XztBdct+lGk7fulGCuXfQ8=";
    arm64-linux_hash = "sha256-Z9K9XY+kJ7JEdBGJPqewodfjtQwQJZ+2LXBH8aQyb1c=";
    x64-osx_hash = "sha256-zLwfAOXIjr3YCs7aVdC1spBhEkPld0ndBPueOTSgkN0=";
  }."${arch}-${os}_hash";
in stdenv.mkDerivation rec {
  pname = "readarr";
  version =
    "0.1.2.1532"; # TODO set up automatic updating with nvfetcher while it's not upstreamed into nixpkgs

  src = fetchurl {
    url =
      "https://github.com/Readarr/Readarr/releases/download/v${version}/Readarr.develop.${version}.${os}-core-${arch}.tar.gz";
    sha256 = hash;
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,share/${pname}-${version}}
    cp -r * $out/share/${pname}-${version}/.
    makeWrapper "${dotnet-runtime}/bin/dotnet" $out/bin/Readarr \
      --add-flags "$out/share/${pname}-${version}/Readarr.dll" \
      --prefix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath [ curl sqlite libmediainfo icu openssl ]
      }

    runHook postInstall
  '';

  passthru = {
    updateScript = ./update.sh;
    tests.smoke-test = nixosTests.readarr;
  };

  meta = with lib; {
    description = "A Usenet/BitTorrent ebook downloader";
    homepage = "https://readarr.com";
    license = licenses.gpl3;
    maintainers = [ maintainers.jocelynthode ];
    sourceProvenance = with lib.sourceTypes; [ binaryBytecode ];
    platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" ];
  };
}
