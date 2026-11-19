# Strata served-model name: `iq3_s` -> the pack the lane actually loads

Status: **code changed 2026-11-19; deploy pending** (tiberius, pius, and the Mac
Hermes app's saved default).

## Why

Generation 109 (2026-11-05) replaced the lane's GSQ-RCO IQ3_S pack with Unsloth
Dynamic V3.1 UD-IQ2_XS but kept the public model name
`qwen3.8-flash-next-iq3_s` "so clients keep working", and kept the lane id
`iq3-s`. Both then named a pack the lane no longer loads. The name was written
in four places (the lane, Hermes, Hindsight and the Hindsight check), so the
prose around them drifted too: `hosts/tiberius.nix` still called IQ3_S "the
served lane ... 24,576 experts, matches the full model" two weeks after the
swap.

An alias would only preserve the lie. The serve layer already answers a request
that names anything else (`serve/server.py`, `model_for`: "Other names are still
served"), so no client needed the old string to keep working - the alias would
exist only to keep saying `iq3_s`.

## What changed

- `profiles/nixos/strata-model.nix` is the one place the name is written:
  `qwen3.8-flash-next-unsloth-ud-iq2_xs`, upstream's own spelling for a set
  (`qwen3.8-flash-next-<family>-<pack>`). The serve layer derives the drafting
  set from this string (`strata_control/drafting.py`, `set_of`), so the name is
  not decoration.
- Lane id `iq3-s` -> `general` (`services.tiberius-strata.model`; the option is
  `coder`/`general`), and the lane's `modelName` reads `strataModel.general`.
- Hermes, Hindsight and `checks/hindsight.nix` read the same constant; the check
  still catches a pius-side override.
- The module/host prose states what is served now and marks the 2026-10-03
  numbers as the record of the packs served then.
- No `aliases` entry anywhere: the old spelling appears only in historical
  records (VALIDATION generations, ab reports, the Round 9 notes).

## Behaviour to verify on deploy

- The drafting set becomes `unsloth-ud-iq2_xs`, which has no `SET_DEFAULTS` or
  `CLASS_DEFAULTS` entry (the old `iq3_s` set had one: CUDA, tuned pack,
  `where = "resident"`). The tuned file is upstream's `strata1` pack; the module
  records the locally converted pack (`4a42b98...`) in `dflash2`, and the tuned
  file would have to have been downloaded separately. It was released after that
  conversion, so check whether it is there before assuming the old entry was
  inert. Check the startup drafting line and `/metrics` on the box, then the
  L-live decode cell against its 113.85 tok/s baseline. If the tuned file was in
  use, the rename ends an inheritance that was measured on IQ3_S, not on this
  pack; that is a decision to take again on measurement, not a reason to keep
  the old name.
- `GET /v1/models` lists only the new id; `GET /props?model=<old>` 404s. Chat
  completions still serve a request that names the old id.
- The Mac Hermes app still has the old id in `~/.hermes/config.yaml`
  (`model.default`, `providers.tiberius-strata.default_model`), and in
  `provider_models_cache.json` / `ui-preferences.json`; repoint it with the app
  closed (the files are app-managed, not Nix-managed).

## Deploy / rollback

tiberius: `nixos-rebuild switch` - the generated config/log names become
`strata-general.*`; watch the journal for the startup drafting line. pius:
deploy; the Hindsight check asserts the new `llmModel`. Then record the
generation in `docs/VALIDATION.md` and update its "Hindsight runtime (pius)"
section, which still names the old id as the current one.

Rollback: revert the commit and switch back. Nothing on disk was renamed - the
pack stayed `ud-iq2_xs`, and `/persist/strata/strata-iq3-s.log` is history, not
a path anything new reads.
