# Strata served-model name: `iq3_s` -> the pack the lane actually loads

Status: **tiberius deployed in generation 116 (2026-11-20); pius and the Mac
Hermes app still name the old id** (verified 2026-11-23).

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

- Resolved: the old `iq3_s` set's CUDA tuned-pack entry went with the name, and
  generation 118 measured upstream's `strata1` tuned drafter directly rather
  than inheriting it: acceptance 78.2 / 77.3 % against the stock pack's 85.3 %,
  decode 104.7 / 104.2 against 111.0 tok/s (-5.7 / -6.1 %), so it is rejected
  and the file stays unused at `/optane/strata-data/dflash2/`
  (`docs/VALIDATION.md`, generation 118). Nothing was lost by dropping the
  entry.
- Generation 116 verified the rename on tiberius: both doors healthy, model
  `qwen3.8-flash-next-unsloth-ud-iq2_xs` loaded, 9,156 expert slots, warm
  completion, no Xid (`docs/VALIDATION.md`, generation 116). `GET /v1/models`
  now lists that id only; `GET /props?model=<old>` 404s, and chat completions
  still serve a request that names the old id.
- The Mac Hermes app still has the old id in `~/.hermes/config.yaml`
  (`model.default`, `providers.tiberius-strata.default_model`) and in
  `~/.hermes/ui-preferences.json`; repoint it in the app or with the app closed
  (the files are app-managed, not Nix-managed).

## Deploy / rollback

tiberius: done as generation 116 (2026-11-20); the generated config/log names
are `strata-general.*`.

pius: not deployed as of 2026-11-23 - `systemctl show hindsight` still reports
`HINDSIGHT_API_LLM_MODEL=qwen3.8-flash-next-iq3_s`, and the reflect model with
it. Requests still work (the serve layer answers the old name), so this is a
naming lag, not an outage. When pius is next switched, update the "Hindsight
runtime (pius)" section of `docs/VALIDATION.md`, which still describes the
running old id accurately.

Rollback: switch tiberius to a generation from before 116 (or revert the commit
and switch). Nothing on disk was renamed - the pack stayed `ud-iq2_xs`, and
`/persist/strata/strata-iq3-s.log` is history, not a path anything new reads.
