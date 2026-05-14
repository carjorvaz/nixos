{
  discord,
  jq,
  lib,
  perl,
  runCommand,
  undmg,
  vesktop,
}:

let
  discordIcns = runCommand "discord-icns" { nativeBuildInputs = [ undmg ]; } ''
    undmg ${discord.src}
    cp Discord.app/Contents/Resources/electron.icns $out
  '';
in
vesktop.overrideAttrs (old: {
  pname = "vesktop-discord";

  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ perl ];

  postPatch = (old.postPatch or "") + ''
    cp ${discordIcns} build/icon.icns

    ${jq}/bin/jq '
      .build.productName = "Discord" |
      .build.executableName = "Discord" |
      .build.appId = "dev.vencord.vesktop-discord" |
      .build.mac.icon = "build/icon.icns" |
      .build.mac.extendInfo.CFBundleDisplayName = "Discord" |
      .build.mac.extendInfo.CFBundleName = "Discord" |
      del(.build.afterPack) |
      del(.build.mac.extendInfo.CFBundleIconName)
    ' package.json > package.json.tmp
    mv package.json.tmp package.json

    # Keep using Vesktop's existing macOS profile directory even though the
    # bundle metadata now presents as Discord.app.
    ${perl}/bin/perl -0pi -e 's@process\.env\.VENCORD_USER_DATA_DIR \|\| \(PORTABLE \? join\(vesktopDir, "Data"\) : join\(app\.getPath\("userData"\)\)\)@process.env.VENCORD_USER_DATA_DIR || (PORTABLE ? join(vesktopDir, "Data") : join(app.getPath("appData"), "Vesktop"))@' src/main/constants.ts
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/{Applications,bin}
    mv dist/mac*/Discord.app $out/Applications/Discord.app
    runHook postInstall
  '';

  postFixup = ''
    makeBinaryWrapper $out/Applications/Discord.app/Contents/MacOS/Discord $out/bin/vesktop-discord

    # Seal the patched bundle metadata so macOS services such as Dock badges,
    # notifications, and TCC see the same bundle identifier as Info.plist.
    /usr/bin/codesign --force --deep --sign - $out/Applications/Discord.app
  '';

  meta = old.meta // {
    description = "Vesktop built as a native-looking Discord.app for macOS";
    mainProgram = "vesktop-discord";
    platforms = lib.platforms.darwin;
  };
})
