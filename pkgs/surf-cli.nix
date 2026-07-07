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

  surf-cli = buildNpmPackage {
    pname = "surf-cli";
    inherit version;

    src = fetchFromGitHub {
      owner = "nicobailon";
      repo = "surf-cli";
      rev = "v${version}";
      hash = "sha256-mGpNQoTcntI7yurVjS2vGKGoOhwBfV1lDOfTU1z7W8c=";
    };

    npmDepsHash = "sha256-oXtBJv1FLFT54mrV7cFY0CIb+CSZhKfShUim4SFHAGA=";

    nativeBuildInputs = [ jq ];
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

      runHook postInstallCheck
    '';

    passthru = {
      inherit extensionId extensionKey;

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
