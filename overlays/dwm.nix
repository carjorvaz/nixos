final: prev: {
  dwm = prev.dwm.overrideAttrs (oldAttrs: rec {
    configFile = prev.writeText "config.h" (builtins.readFile ./dwm-config.h);
    postPatch = oldAttrs.postPatch or "" + ''
      echo 'Using own config file...'
      cp ${configFile} config.def.h'';
  });
}
