# Storage Roles for `mac`, `trajanus`, and `pius`

Observed on 2026-04-19.

This is a cautious planning note for moving the "daily personal/work machine"
role back from `trajanus` to `mac` without losing version history or ending up
with unclear duplicate copies.

## Executive Summary

- `mac` should be the authoritative home for active personal/work files again.
- `trajanus` should become a Linux-first working machine, not the canonical home
  of your long-lived personal archive.
- `pius` should remain the always-on bulk-storage, server-data, and backup box.
- Do not delete old datasets on `pius` yet. Several large ones look like manual
  migration leftovers and are not declared in Nix, but they should be cataloged
  before cleanup.
- `trajanus -> pius` ZFS replication is healthy.
- Mac Time Machine is configured to `pius`, but the sparsebundle directory on
  `pius` appears last modified on 2026-01-10, so Mac backup recency should be
  verified before any destructive cleanup.

## Current State

### `mac`

- APFS system volume: 461G total, 286G used, 176G free.
- Time Machine destination:
  `smb://samba@100.121.87.116/tm_share` with a 1 TB quota.
- Local APFS snapshots visible from `tmutil` were only system update snapshots.
- `~/Documents`: 48G
- `~/Downloads`: 14G
- Largest visible subdirectory in `~/Documents`: `archive` at 42G

Notes:

- Direct size inspection of `~/Pictures/Photos Library.photoslibrary`,
  `~/Music/Music`, and `~/Movies/TV` was inconclusive from this shell because of
  macOS-protected locations.
- `tmutil latestbackup` could not be verified from this shell. The Time Machine
  sparsebundle on `pius` should be checked directly from macOS.

### `trajanus`

- Pool `zroot`: 476G total, 377G allocated, 99.3G free.
- `zroot/local`
  - `/nix`: 53.3G
  - `/`: 213M
- `zroot/safe`
  - `/home`: 265G
  - `/persist`: 61.0G

Snapshot space on `trajanus`:

- `zroot/safe/home`: 72.9G in snapshots
- `zroot/safe/persist`: 6.44G in snapshots

Larger observed paths:

- `~/Downloads`: 53G
- `~/.cache`: 13G
- `~/Documents/archive`: 99G
- `/persist/models`: 42G
- `/persist/var`: 13G

Smaller but still notable:

- `~/Pictures`: 391M
- `~/.local`: 1.4G
- `~/.var`: 1.8G
- `~/.thunderbird`: 1.5G

Backup state:

- `sanoid.timer` healthy
- `syncoid-zroot-safe.timer` healthy
- Latest observed successful `syncoid` run:
  2026-04-19 08:00 WEST

### `pius`

- Pool `zlocal`: 236G total, 23.2G allocated, 213G free.
- Pool `zsafe`: 10.9T total, 5.98T allocated, 4.93T free.

Clearly active roles on `pius`:

- `zsafe/backups`: ZFS replication target
- `zsafe/timemachine`: Mac Time Machine target
- `zsafe/persist`: server/service state

Observed active/bulk data:

- `zsafe/backups/trajanus`: 247G
- `zsafe/timemachine`: 778G
- `/persist/media`: 826G
- `/persist/models`: 60G

Undeclared datasets that look manual or historical:

- `zsafe/aureliusHome`
- `zsafe/aureliusHome20250228`
- `zsafe/aureliusPersist`
- `zsafe/aureliusPersist20250228`
- `zsafe/commodusHome`
- `zsafe/commodusPersist`
- `zsafe/old_mirror_backup_20250414`
- `zsafe/backup_discos_pens_20250416`
- `zsafe/trajanusHome`
- `zsafe/trajanusHome20250317`
- `zsafe/trajanusPersist`
- `zsafe/trajanusPersist20250317`

Only `zsafe/timemachine` is declared in this repo among those names. Most of
the others are strong candidates for "manual migration/import history" rather
than live declarative storage.

## Recommended Stable Roles

### `mac`: authoritative daily machine

Keep here:

- Active personal documents
- Active writing/research
- Current project working trees that you mainly edit from macOS
- Personal app data that is naturally macOS-local
- Photos/Music libraries if you want them locally accessible on the Mac

Avoid treating as canonical here:

- Long-term cold archive that you rarely open
- Server/media collections
- Linux-only build outputs or model caches unless you truly need them local

Backup model:

- Time Machine to `pius`
- Optional second copy of especially important current projects on `pius` or in
  git remotes, but Time Machine should be the baseline

### `trajanus`: Linux-first secondary workstation

Keep here:

- Linux-only development environments
- NixOS/dev infrastructure work
- Temporary downloads
- Local models that benefit from SSD-local access
- Machine-local state in `/persist`

Do not treat as canonical here:

- Your full long-lived personal archive
- Large cold data that is only here because the laptop temporarily became the
  main machine

Goal state:

- `trajanus` should hold the subset of your life/projects that benefits from
  being on Linux, not the default home for everything.

### `pius`: always-on bulk storage, server state, and backups

Keep here:

- Server/service state
- Media library
- Model archive / bulk models
- ZFS backup targets from other machines
- Time Machine target
- Long-term archive datasets that do not need to live on the laptop or Mac SSD

Treat as:

- The authoritative home for bulk and archival data
- The backup target for `trajanus`
- The Time Machine target for `mac`

Do not treat as:

- The primary interactive working copy of your current documents

## Snapshot Strategy

### `trajanus`

Current policy is reasonable during migration:

- frequent/hourly/daily/weekly/monthly/yearly on `zroot/safe`
- replication to `pius` using existing sanoid snapshots

But `trajanus` only has about 99G free, and snapshot usage on `/home` alone is
already 72.9G. That suggests the laptop should stop carrying high-churn cold
data.

Best medium-term improvement:

- Move or split high-churn, low-value paths out of the main `zroot/safe/home`
  dataset, especially:
  - `~/Documents/archive`
  - `~/Downloads`
  - possibly large caches

Good ZFS-specific follow-up later:

- Create child datasets for `~/Downloads` and `~/Documents/archive`, with a much
  lighter snapshot policy or no autosnap at all if they are staging-only.

### `mac`

Use Time Machine as the main versioned backup layer.

Important caution:

- Do not assume the current Time Machine chain is healthy until it is verified.
- The sparsebundle on `pius` appears last modified on 2026-01-10, which is old
  relative to 2026-04-19.

### `pius`

The current ZFS backup-target setup is good:

- longer retention than sources
- receives `trajanus` snapshots successfully

Likely future improvement:

- split some large categories in `zsafe/persist` into dedicated datasets
  (`media`, `models`, maybe `archive`) to make future encryption migration,
  snapshot tuning, and cleanup easier

## Proposed Data Placement Rules

For each category, choose one authoritative machine.

### Active personal/work files

- Authoritative: `mac`
- Backup: Time Machine to `pius`
- Optional working copies: `trajanus` only when needed for Linux-specific work

### Linux-only dev environments and experiments

- Authoritative: `trajanus`
- Backup: ZFS replication to `pius`

### Server/service state

- Authoritative: `pius`
- Backup: future separate plan if needed; this note does not assume those data
  are yet backed up elsewhere

### Bulk media and model archive

- Authoritative: `pius`
- Optional cache/copy: `trajanus` only for the subset you use locally

### Cold archive / migration leftovers

- Prefer authoritative home on `pius`
- Keep a local subset on `mac` only if you actually need regular access

## Cautious Migration Sequence

### Phase 1: confirm safety first

1. Verify Mac Time Machine is healthy and can complete a fresh backup.
2. Keep `trajanus -> pius` replication running unchanged while migrating.
3. Do not delete any `pius` historical datasets yet.

### Phase 2: decide authoritative homes

1. Declare `mac` authoritative for active personal/work files.
2. Declare `trajanus` authoritative only for Linux-specific work.
3. Declare `pius` authoritative for archives, media, models, and backups.

### Phase 3: move data by category, not by machine

Move from `trajanus` to `mac`:

- actively used projects
- active documents
- anything that is now part of the daily Mac workflow

Move from `trajanus` to `pius` instead of to `mac`:

- `Documents/archive`
- old downloads you want to keep but not carry
- bulk model files not needed on the laptop

Leave on `trajanus`:

- Linux-only development state
- temporary downloads
- local caches
- only the models you actually use there

### Phase 4: reduce ambiguity

After the moves:

1. Remove or prune duplicate non-authoritative copies from `trajanus`.
2. Re-evaluate snapshot growth on `trajanus`.
3. Catalog old `pius` datasets and either:
   - rename them into a clear `archive`/`migration` namespace, or
   - delete them only after you are confident they are superseded

## Immediate High-Value Follow-Ups

1. Verify a current Mac Time Machine backup from the Mac UI or `tmutil status`.
2. Inventory the undeclared `zsafe/*` datasets on `pius` and write down what
   each one actually is.
3. Decide whether `Documents/archive` should live primarily on `pius` rather
   than on either workstation.
4. After migration, consider splitting `trajanus` churny paths into their own
   ZFS child datasets with lighter snapshot policy.

## Open Questions

- How large are the Mac Photos/Music/TV libraries in reality?
- Which of the undeclared `pius` datasets are still needed?
- Do you want `pius` to hold a first-class personal archive dataset, or should
  archive data remain partly local on `mac` for offline access?

