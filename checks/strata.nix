{
  pkgs,
  lib,
  tiberius,
}:

let
  strataUnit = tiberius.config.systemd.units."tiberius-strata.service".text or "";
  prepareUnit = tiberius.config.systemd.units."strata-optane-prepare.service".text or "";

  # The rendered unit file separates sections with a blank line, so the body of a
  # section runs from its header line up to the first blank or "[Header]" line.
  # Helpers are local: the pinned lib has no takeWhile, and its splitString
  # treats the separator as a regex, so index the lines instead of splitting on
  # header text.
  idxOf =
    list: pred:
    let
      len = builtins.length list;
      go =
        i:
        if i >= len then
          null
        else if pred (builtins.elemAt list i) then
          i
        else
          go (i + 1);
    in
    go 0;

  takeWhile =
    pred: list:
    let
      len = builtins.length list;
      go = i: if i >= len || !(pred (builtins.elemAt list i)) then i else go (i + 1);
    in
    builtins.genList (j: builtins.elemAt list j) (go 0);

  drop =
    n: list:
    let
      len = builtins.length list;
    in
    builtins.genList (j: builtins.elemAt list (j + n)) (if n >= len then 0 else len - n);

  linesOf = text: builtins.filter builtins.isString (builtins.split "\n" text);

  sectionOf =
    name: text:
    let
      lines = linesOf text;
      start = idxOf lines (l: l == "[${name}]");
      body = if start == null then [ ] else drop (start + 1) lines;
    in
    lib.concatStringsSep "\n" (takeWhile (l: l != "" && !(lib.hasPrefix "[" l)) body);

  unitSection = sectionOf "Unit" strataUnit;
  serviceSection = sectionOf "Service" strataUnit;
  unitLines = linesOf unitSection;
  afterLine = lib.findFirst (l: lib.hasPrefix "After=" l) "" unitLines;

  kernelPatchNames = map (p: p.name) tiberius.config.boot.kernelPatches;
  strataNoWeb = tiberius.config.systemd.services.tiberius-strata.environment.STRATA_NO_WEB or null;

  failures =
    lib.optional (
      !(lib.hasInfix "StartLimitIntervalSec=300" unitSection)
    ) "tiberius-strata.service [Unit] must set StartLimitIntervalSec=300"
    ++ lib.optional (
      !(lib.hasInfix "StartLimitBurst=3" unitSection)
    ) "tiberius-strata.service [Unit] must set StartLimitBurst=3"
    ++ lib.optional (lib.hasInfix "StartLimit" serviceSection) "tiberius-strata.service [Service] must not contain StartLimit* (keep them in unitConfig)"
    ++ lib.optional (
      !(lib.hasInfix "tiberius-qwen38.service" afterLine)
    ) "tiberius-strata.service [Unit] After= must order after tiberius-qwen38.service"
    ++ lib.optional (
      !(lib.hasInfix "tiberius-qwen38-uncensored.service" afterLine)
    ) "tiberius-strata.service [Unit] After= must order after tiberius-qwen38-uncensored.service"
    ++ lib.optional (
      !(lib.hasInfix "tiberius-ninfer.service" afterLine)
    ) "tiberius-strata.service [Unit] After= must order after tiberius-ninfer.service"
    ++ lib.optional (
      !(lib.hasInfix "DefaultDependencies=false" prepareUnit)
    ) "strata-optane-prepare.service must set DefaultDependencies=false"
    ++ lib.optional (
      !(lib.hasInfix "Before=optane.mount" prepareUnit)
    ) "strata-optane-prepare.service must set Before=optane.mount"
    ++ lib.optional (
      !(lib.hasInfix "WantedBy=optane.mount" prepareUnit)
    ) "strata-optane-prepare.service must set WantedBy=optane.mount"
    ++ lib.optional (
      !(builtins.elem "fsdax-longterm-pin" kernelPatchNames)
    ) "boot.kernelPatches must include the fsdax-longterm-pin patch"
    ++ lib.optional (
      !(builtins.elem "fsdax_longterm_pin=1" tiberius.config.boot.kernelParams)
    ) "boot.kernelParams must include fsdax_longterm_pin=1"
    ++ lib.optional (strataNoWeb != "1") "tiberius-strata.service must run with STRATA_NO_WEB=1";
in
{
  tiberius-strata-module-eval =
    if failures == [ ] then
      pkgs.runCommand "tiberius-strata-module-eval" { } "touch $out"
    else
      throw (lib.concatStringsSep "; " failures);
}
