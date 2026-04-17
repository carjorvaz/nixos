{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  buildFHSEnv,
  copyDesktopItems,
  makeDesktopItem,
  writeShellScript,
  gtk3,
  cairo,
  pango,
  gdk-pixbuf,
  glib,
  fontconfig,
  freetype,
  libx11,
  libxext,
  libxi,
  libxrender,
  libxtst,
  libxxf86vm,
  libxfixes,
  libxcomposite,
  libxdamage,
  libxrandr,
  libxcb,
  libxcursor,
  libxshmfence,
  mesa,
  libgbm,
  alsa-lib,
  alsa-plugins,
  ffmpeg_6,
  nss,
  nspr,
  cups,
  dbus,
  expat,
  libdrm,
  at-spi2-core,
  libxkbcommon,
  pciutils,
  systemd,
  zlib,
}:

let
  pname = "ib-tws";
  version = "10.37";

  src = fetchurl {
    url = "https://download2.interactivebrokers.com/installers/tws/stable-standalone/tws-stable-standalone-linux-x64.sh";
    hash = "sha256-IBebvYNowsZEP3w7gdIDTkXVY8sFHSEhqkPaXWapLVI=";
  };

  installerFhs = buildFHSEnv {
    name = "${pname}-installer";
    targetPkgs = _: [ zlib ];
    runScript = "";
  };

  unwrapped = stdenvNoCC.mkDerivation {
    pname = "${pname}-unwrapped";
    inherit version src;

    dontUnpack = true;

    installPhase = ''
      runHook preInstall

      cp $src installer.sh
      chmod +x installer.sh

      ${installerFhs}/bin/${pname}-installer ./installer.sh -q -dir $TMPDIR/tws

      mkdir -p $out/lib/${pname}
      cp -r $TMPDIR/tws/jars $out/lib/${pname}/
      cp -r $TMPDIR/tws/data $out/lib/${pname}/
      cp $TMPDIR/tws/tws.vmoptions $out/lib/${pname}/
      cp -r $TMPDIR/tws/.install4j $out/lib/${pname}/

      jre_java=$(find "$NIX_BUILD_TOP" -path "*/i4j_jres/*/bin/java" -print -quit)
      if [[ -z "$jre_java" ]]; then
        echo "error: could not find bundled JRE" >&2
        exit 1
      fi
      cp -r "$(dirname "$(dirname "$jre_java")")" $out/lib/${pname}/jre

      runHook postInstall
    '';

    meta = {
      inherit (meta) description homepage license;
      sourceProvenance = with lib.sourceTypes; [
        binaryBytecode
        binaryNativeCode
      ];
      platforms = [ "x86_64-linux" ];
    };
  };

  fhsEnv = buildFHSEnv {
    name = pname;
    inherit meta;

    targetPkgs = _: [
      gtk3
      cairo
      pango
      gdk-pixbuf
      glib
      fontconfig
      freetype
      libx11
      libxext
      libxi
      libxrender
      libxtst
      libxxf86vm
      libxfixes
      libxcomposite
      libxdamage
      libxrandr
      libxcb
      libxcursor
      libxshmfence
      mesa
      libgbm
      alsa-lib
      alsa-plugins
      ffmpeg_6
      nss
      nspr
      cups
      dbus
      expat
      libdrm
      at-spi2-core
      libxkbcommon
      pciutils
      systemd
      zlib
      stdenv.cc.cc.lib
    ];

    runScript = writeShellScript "${pname}-launch" ''
      TWS_HOME="${unwrapped}/lib/${pname}"
      CONFIG_DIR="''${IB_TWS_CONFIG_DIR:-$HOME/.ib-tws}"
      mkdir -p "$CONFIG_DIR"

      exec "$TWS_HOME/jre/bin/java" \
        -Xmx2048m \
        -XX:+UseG1GC \
        -XX:MaxGCPauseMillis=200 \
        -XX:ParallelGCThreads=20 \
        -XX:ConcGCThreads=5 \
        -XX:InitiatingHeapOccupancyPercent=70 \
        -Dsun.awt.nopixfmt=true \
        -Dsun.java2d.noddraw=true \
        -Dswing.boldMetal=false \
        -Dsun.locale.formatasdefault=true \
        --add-opens=java.base/java.util=ALL-UNNAMED \
        --add-opens=java.base/java.util.concurrent=ALL-UNNAMED \
        --add-exports=java.base/sun.util=ALL-UNNAMED \
        --add-exports=java.desktop/com.sun.java.swing.plaf.motif=ALL-UNNAMED \
        --add-opens=java.desktop/java.awt=ALL-UNNAMED \
        --add-opens=java.desktop/java.awt.dnd=ALL-UNNAMED \
        --add-opens=java.desktop/javax.swing=ALL-UNNAMED \
        --add-opens=java.desktop/javax.swing.event=ALL-UNNAMED \
        --add-opens=java.desktop/javax.swing.plaf.basic=ALL-UNNAMED \
        --add-opens=java.desktop/javax.swing.table=ALL-UNNAMED \
        --add-opens=java.desktop/sun.awt=ALL-UNNAMED \
        --add-exports=java.desktop/sun.awt.X11=ALL-UNNAMED \
        --add-exports=java.desktop/sun.swing=ALL-UNNAMED \
        --add-opens=javafx.graphics/com.sun.javafx.application=ALL-UNNAMED \
        --add-exports=javafx.media/com.sun.media.jfxmedia=ALL-UNNAMED \
        --add-exports=javafx.media/com.sun.media.jfxmedia.events=ALL-UNNAMED \
        --add-exports=javafx.media/com.sun.media.jfxmedia.locator=ALL-UNNAMED \
        --add-exports=javafx.media/com.sun.media.jfxmediaimpl=ALL-UNNAMED \
        --add-exports=javafx.web/com.sun.javafx.webkit=ALL-UNNAMED \
        --add-exports=javafx.web/com.sun.webkit=ALL-UNNAMED \
        --add-opens=jdk.management/com.sun.management.internal=ALL-UNNAMED \
        -DinstallDir="$TWS_HOME/" \
        -DjtsConfigDir="$CONFIG_DIR" \
        -Dchannel=stable \
        -DprivateLabel=ib \
        -DproductName="Trader Workstation" \
        -classpath "$TWS_HOME/.install4j/*:$TWS_HOME/jars/*" \
        install4j.jclient.LoginFrame \
        "$CONFIG_DIR" \
        "$@"
    '';
  };

  meta = {
    description = "Interactive Brokers Trader Workstation";
    homepage = "https://www.interactivebrokers.com";
    sourceProvenance = with lib.sourceTypes; [
      binaryBytecode
      binaryNativeCode
    ];
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    mainProgram = pname;
  };
in
stdenvNoCC.mkDerivation {
  inherit pname version meta;

  dontUnpack = true;

  nativeBuildInputs = [ copyDesktopItems ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    ln -s ${fhsEnv}/bin/${pname} $out/bin/${pname}

    mkdir -p $out/share/icons/hicolor/128x128/apps
    ln -s ${unwrapped}/lib/${pname}/.install4j/tws.png \
      $out/share/icons/hicolor/128x128/apps/${pname}.png

    runHook postInstall
  '';

  desktopItems = [
    (makeDesktopItem {
      name = pname;
      desktopName = "Trader Workstation";
      exec = pname;
      icon = pname;
      comment = meta.description;
      categories = [ "Office" ];
    })
  ];
}
