# Future Storage Layout Proposal for `mac`, `trajanus`, and `pius`

Companion note to
`docs/storage-roles-mac-trajanus-pius-2026-04-19.md`.

This note goes one layer deeper:

- what the current storage shape implies
- what the main risks are
- what a cleaner future dataset hierarchy could look like
- what to prioritize before any cleanup

## Main Findings

### 1. `pius` live data is the biggest current protection gap

`pius` is not just a backup target. It also holds:

- server/service state
- media
- model files
- a very large archive bucket
- Mac Time Machine data

But the current repo only configures `pius` as:

- `services.zfsBackup.target`
- a prune-only sanoid setup for `zsafe/backups`

What is *not* configured today:

- `pius` as a ZFS backup source
- recurring sanoid snapshots for `zsafe/persist`

Observed live snapshots on `zsafe/persist`:

- `zsafe/persist@20231203`
- `zsafe/persist@20240609`
- `zsafe/persist@20250306`

So `pius` has only three old manual snapshots for its live state, even though:

- `zsafe/persist` is 2.40T referenced
- `zsafe/persist` has 266G in snapshot-held space
- `zsafe/persist` has 528G written since its most recent snapshot

That makes `pius` the top priority for future snapshot/backup work.

### 2. `trajanus` is carrying too much long-lived bulk data

Observed on `trajanus`:

- `zroot` free space: about 99G
- `zroot/safe/home`: 265G
- `zroot/safe/persist`: 61G
- `zroot/safe/home` snapshots: 72.9G

Largest visible contributors:

- `~/Documents/archive`: 99G
- `~/Downloads`: 53G
- `~/.cache`: 13G
- `/persist/models`: 42G

Largest visible archive items include:

- `documents_mac_20251228`: 43G
- `h`: 15G
- `Ryujinx_20250221`: 12G
- `wii_games`: 7.6G
- `hacker-news`: 5.4G
- `pdf_translator_rs_20260202`: 5.3G
- `office_20250125`: 3.6G

Largest visible downloads include:

- `mirror`: 47G
- multiple emulator/code guide directories in the 300M-700M range

So the laptop is still acting like a semi-archive store, not a focused working
machine.

### 3. `pius` contains multiple layers of historical copies

There are at least three kinds of old/historical storage on `pius`:

1. Current ZFS replication targets under `zsafe/backups/*`
2. Manual or historical ZFS datasets such as:
   - `zsafe/trajanusHome`
   - `zsafe/trajanusHome20250317`
   - `zsafe/trajanusPersist`
   - `zsafe/trajanusPersist20250317`
   - `zsafe/commodusHome`
   - `zsafe/commodusPersist`
   - `zsafe/aureliusHome`
   - `zsafe/aureliusPersist`
   - `zsafe/old_mirror_backup_20250414`
   - `zsafe/backup_discos_pens_20250416`
3. Archive directories inside current live storage:
   - `/persist/archive/backup_trajanus_20240808`
   - `/persist/archive/backup_persist_commodus_20241206`
   - `/persist/archive/backup_zmedia_20240727`
   - and others

This means cleanup later should treat `pius` as a layered storage history, not a
single clean backup namespace.

### 4. `pius` already has clear bulk-storage buckets hiding inside `zsafe/persist`

Observed inside current live storage:

- `/persist/archive`
  - `backup_persist_commodus_20241206`: 451G
  - `backup_zmedia_20240727`: 417G
  - `backup_disco_portatil_asus_antigo_20240727.img`: 221G
  - `cursos_mega_20241228`: 197G
  - `backup_trajanus_20240808`: 65G

- `/persist/media`
  - `tv`: 354G
  - `downloads`: 241G
  - `movies`: 220G
  - `documentaries`: 9.0G
  - `books`: 2.5G
  - `audiobooks`: 1.4G

- `/persist/models`
  - `Qwen3-Coder-Next-IQ4_KSS.gguf`: 40G
  - `Qwen3.5-35B-A3B-Q4_K_M-00002-of-00002.gguf`: 21G

- `/persist/var/lib`
  - `nextcloud`: 205G
  - `clickhouse`: 15G
  - `open-webui`: 870M
  - `jellyfin`: 425M
  - `postgresql`: 322M
  - `transmission`: 117M

This is why splitting by category is worth it. The current single `zsafe/persist`
dataset is simultaneously:

- a huge cold archive
- a media library
- a download staging area
- a model store
- live service/app state

### 5. Time Machine exists, but freshness still needs confirmation

Observed on `mac`:

- Time Machine destination points to `smb://samba@100.121.87.116/tm_share`
- `tmutil status` showed no currently running backup

Observed on `pius`:

- `zsafe/timemachine`: 778G
- `MacBook Pro.sparsebundle` directory last modified on 2026-01-10

That does not prove backups are broken, but it is old enough that recency
should be confirmed before trusting it as the main safety net.

### 6. Syncthing is intentionally narrow today

`trajanus` syncs only:

- `/home/cjv/org`
- `/home/cjv/Documents/tese`

with `mac`.

This is actually a good sign: there is not already a giant automatic bidirectional
mesh to untangle. The authoritative-home decision can stay simple.

## What Each Machine Should Be Optimized For

### `mac`

Optimize for:

- active personal/work documents
- active writing/research
- daily-use personal data
- macOS-native libraries and apps

Do not optimize for:

- giant archives
- Linux-specific cache/build state
- server/media/model bulk storage

### `trajanus`

Optimize for:

- Linux-specific development
- NixOS/infra work
- temporary downloads
- a small local working set of models
- only the active subset of documents that benefit from Linux access

Do not optimize for:

- carrying your whole long-lived archive
- carrying mirrored Mac history indefinitely

### `pius`

Optimize for:

- always-on server data
- bulk storage
- media library
- model archive
- cold archive
- Time Machine target
- ZFS replication target

Do not optimize for:

- being the main interactive working copy of current documents

## Proposed Future Dataset Hierarchy

This is not a command plan yet. It is the shape I would aim toward.

### `trajanus`

Keep:

- `zroot/local/root`
- `zroot/local/nix`
- `zroot/safe/persist`

Split out of the current `/home` dataset:

- `zroot/safe/home-main`
  mountpoint: `/home`
  purpose: normal active user data

- `zroot/safe/home-downloads`
  mountpoint: `/home/cjv/Downloads`
  purpose: transient intake/staging

- `zroot/safe/home-archive`
  mountpoint: `/home/cjv/Documents/archive`
  purpose: local archive subset only if still needed on laptop

Optional:

- `zroot/safe/persist-models`
  mountpoint: `/persist/models`
  purpose: local model working set

Why this split helps:

- heavy churn in `Downloads` stops inflating snapshots for all of `/home`
- archive data gets a lighter policy than active work
- models can be managed separately from general persistent machine state

### `pius`

Keep unchanged:

- `zsafe/backups`
- `zsafe/timemachine`
- `zsafe/samba`

Split `zsafe/persist` into categories with different risk/churn profiles:

- `zsafe/archive`
  mountpoint: `/persist/archive`
  purpose: cold/archive/bulk retained history

- `zsafe/media`
  mountpoint: `/persist/media`
  purpose: stable media library

- `zsafe/media-downloads`
  mountpoint: `/persist/media/downloads`
  purpose: active download intake

- `zsafe/models`
  mountpoint: `/persist/models`
  purpose: model store

- `zsafe/appstate`
  mountpoint: `/persist/var`
  purpose: live service state

Optional but very attractive:

- `zsafe/nextcloud`
  mountpoint: `/persist/var/lib/nextcloud`
  purpose: nextcloud data and app state

- `zsafe/postgresql`
  mountpoint: `/persist/var/lib/postgresql`
  purpose: postgres data

- `zsafe/clickhouse`
  mountpoint: `/persist/var/lib/clickhouse`
  purpose: clickhouse data

- `zsafe/config`
  mountpoint: `/persist/etc`
  purpose: host-specific persisted config such as SSH state

Why this split helps:

- archive, media, downloads, and app state stop sharing one retention policy
- high-value app data can get aggressive snapshots
- bulky low-value churn like downloads can get almost none
- future encryption migration on `pius` becomes easier dataset-by-dataset

## Suggested Snapshot Policies by Data Class

These are policy ideas, not current config.

### Active work

Use for:

- `trajanus` active home/work dataset
- possibly `pius` appstate / nextcloud

Suggested retention:

- frequent: 4
- hourly: 24
- daily: 14
- weekly: 8
- monthly: 12
- yearly: 3

### Archive

Use for:

- `pius` archive
- maybe `trajanus` local archive subset if it remains

Suggested retention:

- frequent: 0
- hourly: 0
- daily: 7
- weekly: 8
- monthly: 24
- yearly: 5

Reasoning:

- archive is high-value but low-churn
- you care more about long history than dense short-term rollback

### Media library

Use for:

- `pius` movies/tv/books/documentaries/audiobooks

Suggested retention:

- frequent: 0
- hourly: 0
- daily: 0
- weekly: 4
- monthly: 12
- yearly: 3

Reasoning:

- media changes are relatively infrequent
- snapshots are useful mainly against accidental deletion or bad batch moves

### Downloads / staging

Use for:

- `trajanus` `Downloads`
- `pius` `/persist/media/downloads`

Suggested retention:

- either `autosnap = false`
- or only:
  - daily: 2
  - weekly: 1

Reasoning:

- high churn, low long-term value
- not worth bloating snapshot usage

### Models

Use for:

- `pius` models
- any local model working set on `trajanus`

Suggested retention:

- `autosnap = false`
- or monthly only

Reasoning:

- model files are usually replaceable and large
- snapshots can waste a lot of space for little real benefit

### Time Machine dataset

Use for:

- `zsafe/timemachine`

Suggested retention:

- probably no extra ZFS snapshots

Reasoning:

- Time Machine already contains its own version history
- ZFS snapshots here mostly add duplication of versioned backup data

## What Should Be Authoritative Where

### Personal active documents

- authoritative: `mac`
- backup: Time Machine to `pius`
- optional working copy: `trajanus` only when needed

### Linux development and infra work

- authoritative: `trajanus`
- backup: ZFS replication to `pius`

### Org/thesis

Current setup is already sensible:

- active on both `mac` and `trajanus`
- synced narrowly with Syncthing
- still additionally protected by the machine-level backup systems

### Cold archive

- authoritative: `pius`
- optional subset cached locally on `mac`
- avoid making `trajanus` the default home for archive bulk

### Server/media/models

- authoritative: `pius`

## Immediate Priorities

In order:

### Priority 1: verify Mac backup freshness

Before any destructive migration:

- confirm a recent successful Time Machine backup from the Mac itself
- if needed, trigger a new backup and confirm completion

### Priority 2: establish real snapshot coverage for `pius` live data

Before cleanup:

- give `pius` recurring snapshots for live datasets
- ideally after or alongside splitting out `archive`, `media`, `downloads`,
  `models`, and `appstate`

### Priority 3: stop storing cold bulk on `trajanus`

Move off the laptop first:

- `~/Documents/archive`
- `~/Downloads/mirror`
- anything else that is clearly retained bulk rather than active work

Likely destination:

- mostly `pius`
- only a selected active subset to `mac`

### Priority 4: catalog historical `pius` datasets before deleting anything

Especially:

- `zsafe/trajanusHome*`
- `zsafe/trajanusPersist*`
- `zsafe/commodus*`
- `zsafe/aurelius*`
- old mirror/import datasets

Best outcome:

- rename or reclassify them into a clearly historical namespace later
- only delete after supersession is obvious

## Conservative Migration Sequence

### Phase A: protect first

1. Verify Time Machine on `mac`
2. Keep `trajanus -> pius` replication unchanged
3. Add snapshot coverage plan for `pius` live datasets

### Phase B: reduce laptop pressure

1. Move `trajanus` archive bulk to `pius`
2. Move only the active personal/work subset from `trajanus` to `mac`
3. Leave Linux-specific data on `trajanus`

### Phase C: reshape `pius`

1. Split live categories into dedicated datasets
2. Apply category-specific snapshot policies
3. Decide how `pius` itself will be backed up off-host or to removable media

### Phase D: clean historical clutter

1. Map old datasets to their real meaning
2. Rename, archive, or delete only after verification

## Strong Candidate Layout Decisions

If I had to make only a few high-confidence choices now, they would be:

1. `Documents/archive` belongs primarily on `pius`, not on `trajanus`.
2. `Downloads` should never share the same snapshot policy as active work.
3. `pius` needs live snapshots more urgently than it needs cleanup.
4. `nextcloud`, `media`, `archive`, and `models` should not all live inside one
   generic `zsafe/persist` bucket long-term.
5. `mac` should hold the active daily personal/work set, not every historical
   copy.
