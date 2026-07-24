{ vencord }:

vencord.overrideAttrs (old: {
  pname = "vencord-manual-archive";

  postPatch = (old.postPatch or "") + ''
    mkdir -p src/userplugins/manualChannelArchive
    cp ${./plugin/archive.ts} src/userplugins/manualChannelArchive/archive.ts
    cp ${./plugin/index.tsx} src/userplugins/manualChannelArchive/index.tsx
    cp ${./plugin/native.ts} src/userplugins/manualChannelArchive/native.ts
    cp ${./plugin/state.ts} src/userplugins/manualChannelArchive/state.ts
  '';

  meta = old.meta // {
    description = "Vencord with the explicit manual channel text archive plugin";
  };
})
