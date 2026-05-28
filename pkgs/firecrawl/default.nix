{
  callPackage,
  cargo,
  fetchFromGitHub,
  fetchPnpmDeps,
  fetchurl,
  lib,
  makeWrapper,
  nodejs_22,
  openssl,
  path,
  pkg-config,
  pnpm_10,
  python3,
  rustPlatform,
  rustc,
  stdenv,
}:

let
  # crates.io rejects the generic fetcher User-Agent currently used by this
  # nixpkgs revision for Cargo registry downloads. Keep the workaround local to
  # this package so the rest of the Cargo vendoring path remains the standard
  # rustPlatform.importCargoLock implementation.
  fetchurlWithCratesIoUserAgent =
    args:
    fetchurl (
      args
      // {
        curlOptsList = (args.curlOptsList or [ ]) ++ [
          "-A"
          "nixpkgs-firecrawl-cargo-vendor/1.0 (https://github.com/NixOS/nixpkgs)"
        ];
      }
    );

  importCargoLockWithCratesIoUserAgent =
    callPackage (path + "/pkgs/build-support/rust/import-cargo-lock.nix")
      {
        fetchurl = fetchurlWithCratesIoUserAgent;
      };
in

stdenv.mkDerivation (finalAttrs: {
  pname = "firecrawl";
  version = "0-unstable-2026-05-27";

  src = fetchFromGitHub {
    owner = "firecrawl";
    repo = "firecrawl";
    rev = "986864033d9634f5155a6c95b0329771c8256e46";
    hash = "sha256-UVFnL5KT3aODNmzhioQVUkpX0AdQwWfO3h0p/LgA62g=";
  };

  sourceRoot = "${finalAttrs.src.name}/apps/api";

  patches = [
    # The API server honors HOST, but worker health/metrics endpoints otherwise
    # listen on every interface. Keep private deployments loopback-only by
    # applying the same HOST binding to those liveness servers.
    ./bind-worker-health-to-host.patch
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs)
      pname
      version
      src
      sourceRoot
      ;
    pnpm = pnpm_10;
    fetcherVersion = 3;
    hash = "sha256-9lCJPKDSspWN9XJvJn/oxHkp91WzaG/Y264RPqBP8VM=";
  };

  cargoRoot = "native";
  cargoDeps = importCargoLockWithCratesIoUserAgent {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "calamine-0.34.0" = "sha256-LdO0GtnBN2aJlw/Coy0/aYkzOGtt9vnJf0Vj3EyUvO0=";
      "lopdf-0.40.0" = "sha256-YB0wIScETJeOAezXgpHPzEl0OcMSMHrsMLwrgghMe1A=";
      "nodesig-1.0.0" = "sha256-5n3SSEVqtRU5IyISk82jrQ9R1vRZFeBjfhP/GPL+5G4=";
      "pdf-inspector-0.1.0" = "sha256-44Dy8LnrOhqz6iKbEaxWLLsI4xB06fF7DvEl3rvyZDU=";
    };
  };

  nativeBuildInputs = [
    cargo
    makeWrapper
    nodejs_22
    pkg-config
    pnpm_10
    pnpm_10.configHook
    python3
    rustPlatform.cargoSetupHook
    rustc
  ];

  buildInputs = [
    openssl
  ];

  env = {
    CI = "true";
    COREPACK_ENABLE_DOWNLOAD_PROMPT = "0";
    COREPACK_ENABLE_PROJECT_SPEC = "0";
    npm_config_manage_package_manager_versions = "false";
    npm_config_offline = "true";
    npm_config_package_manager_strict = "false";
  };

  prePatch = ''
    cp ${./Cargo.lock} native/Cargo.lock
  '';

  buildPhase = ''
    runHook preBuild

    export CARGO_NET_OFFLINE=true
    export npm_config_nodedir=${nodejs_22}

    pnpm --filter @mendable/firecrawl-rs run build
    pnpm run build

    # Recreate node_modules with production dependencies only. Keep HOME from
    # pnpmConfigHook intact here; it carries the offline store-dir config.
    rm -rf node_modules native/node_modules
    pnpm install --prod --offline --ignore-scripts --frozen-lockfile

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    appDir=$out/share/firecrawl/apps/api
    mkdir -p $appDir $out/bin

    cp -R dist package.json node_modules native sharedLibs $appDir/

    rm -rf \
      $appDir/native/node_modules \
      $appDir/native/target

    find $appDir/native -mindepth 1 -maxdepth 1 \
      ! -name 'package.json' \
      ! -name 'index.js' \
      ! -name 'index.d.ts' \
      ! -name '*.node' \
      ! -name 'wasi-worker-browser.mjs' \
      -exec rm -rf {} +

    makeWrapper ${lib.getExe nodejs_22} $out/bin/firecrawl-api \
      --run "cd $appDir" \
      --add-flags dist/src/index.js

    makeWrapper ${lib.getExe nodejs_22} $out/bin/firecrawl-worker \
      --run "cd $appDir" \
      --add-flags dist/src/services/queue-worker.js

    makeWrapper ${lib.getExe nodejs_22} $out/bin/firecrawl-extract-worker \
      --run "cd $appDir" \
      --add-flags dist/src/services/extract-worker.js

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    cd $out/share/firecrawl/apps/api
    ${lib.getExe nodejs_22} -e 'const native = require("./native"); if (!native.processPdf) throw new Error("native module did not load")'
    ${lib.getExe nodejs_22} --check dist/src/index.js
    ${lib.getExe nodejs_22} --check dist/src/services/queue-worker.js
    ${lib.getExe nodejs_22} --check dist/src/services/extract-worker.js

    runHook postInstallCheck
  '';

  meta = {
    description = "API server for Firecrawl, a web data extraction platform";
    homepage = "https://github.com/firecrawl/firecrawl";
    license = lib.licenses.agpl3Only;
    mainProgram = "firecrawl-api";
    platforms = lib.platforms.linux;
    sourceProvenance = with lib.sourceTypes; [ fromSource ];
  };
})
