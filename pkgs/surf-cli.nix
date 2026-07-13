{
  buildNpmPackage,
  fetchFromGitHub,
  jq,
  lib,
  nodejs,
  stdenvNoCC,
  writeShellApplication,
}:

let
  version = "2.8.0";

  # Public key only. This pins the unpacked Chromium extension ID so the
  # native-messaging host manifest can be generated declaratively. The matching
  # private key is intentionally not needed unless this becomes a signed CRX.
  extensionKey = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxgv0Zk6Q0X43KE9xpjKzi8UO1YZANdqhANQEKUz37cg1dGQxjYh4NUOjBPoJ8NQckKtwMFq6dcAM/eKNjfbLSrSTPJJKImPYyi9JMAxOxS1tkWk+6rYmr93J/K9cU6Cs6u1OZZlFPj/xVjfzqVBwrjLr1HRHOSQVDopqJmIpMHa3/8p4w84CyhczyC/Lkz1qtyA9Wf0M1YzF6C1c0mcj6MKEqUg0NrAtGwhqNKh1vQz3/B7M6W5QwB4L3j0JO/7kXT2HIBVprUkYpdvN6sitwIFNdl4Fc1zubwTuqcVNNeDRY+lxAllLYDV3Cd6OfJLngObgaQSwRYj46wb4E7kJ0wIDAQAB";
  extensionId = "lnblfmkpkkjfjblnkepghicifnlcolak";

  src = fetchFromGitHub {
    owner = "nicobailon";
    repo = "surf-cli";
    rev = "v${version}";
    hash = "sha256-mGpNQoTcntI7yurVjS2vGKGoOhwBfV1lDOfTU1z7W8c=";
  };

  surf-cli = buildNpmPackage {
    # Keep the high-privilege extension narrow: secure runtime state, disable
    # the Pi-auth bridge and payload logs, remove unused browser polyfills, and
    # refresh vulnerable transitive dependencies within upstream semver ranges.
    patches = [ ../patches/surf-cli-local-hardening.patch ];
    pname = "surf-cli";
    inherit src version;

    postPatch = ''
      cp ${./surf-cli-package-lock.json} package-lock.json
    '';

    npmDepsHash = "sha256-xBQy8eWwMjQXPQedZxH5gEHKfR65DjJ67JxNoyH6gLI=";

    nativeBuildInputs = [ jq ];

    doCheck = true;
    checkPhase = ''
      runHook preCheck
      npm test -- --run
      runHook postCheck
    '';
    nativeInstallCheckInputs = [ jq ];

    postInstall = ''
      manifest="$out/lib/node_modules/surf-cli/dist/manifest.json"
      jq \
        --arg key '${extensionKey}' \
        --arg version '${version}' \
        '.key = $key | .version = $version' \
        "$manifest" > "$manifest.tmp"
      mv "$manifest.tmp" "$manifest"
    '';

    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      "$out/bin/surf" --help >/dev/null
      jq \
        --arg key '${extensionKey}' \
        --arg version '${version}' \
        -e '.key == $key and .version == $version and (.permissions | index("nativeMessaging"))' \
        "$out/lib/node_modules/surf-cli/dist/manifest.json" >/dev/null
      grep -Fq 'SURF_STATE_DIR' \
        "$out/lib/node_modules/surf-cli/native/socket-path.cjs"
      grep -Fq 'SURF_STATE_DIR' \
        "$out/lib/node_modules/surf-cli/native/doctor.cjs"
      grep -Fq 'SURF_DEBUG_LOG' \
        "$out/lib/node_modules/surf-cli/native/host.cjs"
      if grep -Fq '"/tmp/surf.sock"' \
        "$out/lib/node_modules/surf-cli/native/doctor.cjs"; then
        echo "Surf doctor must use the hardened state socket" >&2
        exit 1
      fi
      if grep -Fq 'AUTH_FILE' \
        "$out/lib/node_modules/surf-cli/native/host.cjs"; then
        echo "Surf native host must not read Pi authentication state" >&2
        exit 1
      fi
      if grep -Fq 'Received from extension: ''${JSON.stringify(msg)}' \
        "$out/lib/node_modules/surf-cli/native/host.cjs"; then
        echo "Surf native host must not log extension payloads" >&2
        exit 1
      fi

      runHook postInstallCheck
    '';

    passthru = {
      inherit extensionId extensionKey;
      surfSkill = "${surf-cli}/lib/node_modules/surf-cli/skills/surf";

      chromeExtension = stdenvNoCC.mkDerivation {
        pname = "surf-cli-chrome-extension";
        inherit version;

        dontUnpack = true;

        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          cp -R ${surf-cli}/lib/node_modules/surf-cli/dist/. "$out/"
          runHook postInstall
        '';

        passthru = {
          inherit extensionId extensionKey;
        };

        meta = {
          description = "Unpacked Chromium extension for Surf CLI";
          homepage = "https://github.com/nicobailon/surf-cli";
          license = lib.licenses.mit;
          platforms = lib.platforms.darwin ++ lib.platforms.linux;
        };
      };

      nativeHost = writeShellApplication {
        name = "surf-browser-native-host";
        text = ''
          cd ${surf-cli}/lib/node_modules/surf-cli/native
          exec ${nodejs}/bin/node ${surf-cli}/lib/node_modules/surf-cli/native/host.cjs "$@"
        '';
        meta = {
          description = "Native messaging host wrapper for Surf CLI";
          homepage = "https://github.com/nicobailon/surf-cli";
          license = lib.licenses.mit;
          mainProgram = "surf-browser-native-host";
          platforms = lib.platforms.darwin ++ lib.platforms.linux;
        };
      };
    };

    meta = {
      description = "CLI for AI agents to control Chrome-family browsers";
      homepage = "https://github.com/nicobailon/surf-cli";
      license = lib.licenses.mit;
      mainProgram = "surf";
      platforms = lib.platforms.darwin ++ lib.platforms.linux;
    };
  };
in
surf-cli
