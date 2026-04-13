{
  lib,
  discord,
  runCommand,
  symlinkJoin,
  undmg,
  vesktop,
}:

# Vesktop with Discord's icon, in a Discord.app bundle.
#
# Editing Info.plist (for example to change CFBundleDisplayName) breaks
# Electron's runtime bundle checks even after re-signing, so leave the
# upstream metadata alone and only swap the app icon.
let
  discordIcns = runCommand "discord-icns" { nativeBuildInputs = [ undmg ]; } ''
    undmg ${discord.src}
    cp Discord.app/Contents/Resources/electron.icns $out
  '';
in
symlinkJoin {
  name = "vesktop-discord";
  paths = [ vesktop ];

  postBuild = ''
    mv $out/Applications/Vesktop.app $out/Applications/Discord.app
    contents=$out/Applications/Discord.app/Contents
    rm $contents/Resources/icon.icns
    cp ${discordIcns} $contents/Resources/icon.icns
  '';

  meta = {
    description = "Vesktop wrapped in a Discord.app bundle with Discord's icon";
    homepage = "https://github.com/Vencord/Vesktop";
    license = vesktop.meta.license;
    mainProgram = "Discord";
    platforms = lib.platforms.darwin;
  };
}
