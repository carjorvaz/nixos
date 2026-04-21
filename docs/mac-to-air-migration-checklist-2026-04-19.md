# Mac to 256GB Air Migration Checklist

Observed on 2026-04-19.

Goal: make the move to the incoming 256GB/32GB M4 Air calm and deliberate,
without treating the new machine as a byte-for-byte clone target.

## Core Idea

Do **not** think of this as "move the whole old Mac to the new Mac".

Given this repo already defines the macOS setup declaratively, the healthier
model is:

1. Rebuild the new Air from Nix/Homebrew
2. Migrate only the data and app state that truly belong on a small daily
   machine
3. Leave archive/bulk history on `pius`

That matters because a lot of the current Mac footprint is re-creatable rather
than precious.

## Current Observed Footprint

### Whole machine

- APFS volume: 461G total, 286G used, 176G free

### Large areas that are mostly re-creatable

- `/nix`: 58G
- `/Applications`: 13G
- `/opt/homebrew`: 1.2G

These should generally **not** drive the Air migration plan.

### User home

Accessible shell-visible footprint:

- `/Users/cjv`: 114G

Important caveat:

- This undercounts protected media libraries in `Pictures`, `Music`, and
  `Movies`, so manual Finder checks are still needed.

### Biggest visible areas in home

- `~/Documents`: 48G
- `~/Library`: 29G
- `~/Downloads`: 14G
- `~/.colima`: 10G
- `~/.cache`: 5.4G
- `~/.config`: 3.3G
- `~/.julia`: 2.8G
- `~/.codex`: 1.1G

### `~/Documents`

- `archive`: 42G
- `ComfyUI`: 3.0G
- `tese`: 1.9G
- `open-webui`: 889M
- `JiL.jl`: 98M
- `nixos`: 31M

### `~/Downloads`

Largest visible items:

- `videos`: 5.7G
- `pdf-translator-experiment`: 1.7G
- `I got fired for this ... .webm`: 1.4G
- `The greatest game of GeoGuessr.. .mp4`: 748M
- partial/temporary video files in the ~700M range

### `~/Library`

Largest visible subtrees:

- `Application Support`: 15G
- `Caches`: 12G
- `Containers`: 1.5G
- `Group Containers`: 354M

Largest visible `Application Support` areas:

- `stremio-server`: 5.8G
- `BraveSoftware`: 1.9G
- `discord`: 1.5G
- `VSCodium`: 1.3G
- `Signal`: 920M
- `com.apple.wallpaper`: 911M
- `Firefox`: 722M
- `vesktop`: 384M
- `Zed`: 353M
- `Ryujinx`: 334M

Largest visible `Caches` areas:

- `Homebrew`: 3.9G
- `BraveSoftware`: 1.7G
- `zen`: 1.1G
- `pip`: 1.1G
- `com.kagi.kagimacOS`: 925M
- `Firefox`: 840M
- `com.apple.icloudmailagent`: 313M
- `com.apple.textunderstandingd`: 301M

### Hidden/dev/cached areas

- `~/.colima/_lima`: 10G
- `~/.cache/uv`: 2.1G
- `~/.cache/nix`: 1.7G
- `~/.cache/huggingface`: 1.6G
- `~/.julia/compiled`: 2.0G
- `~/.julia/juliaup`: 783M
- `~/.config/emacs`: 3.3G

## What Should Probably Not Be Migrated As-Is

These should be rebuilt, reinstalled, or repopulated on the Air rather than
copied wholesale:

- `/nix`
- most of `/Applications`
- most of `/opt/homebrew`
- `~/.colima`
- caches in `~/Library/Caches`
- caches in `~/.cache`
- most download leftovers in `~/Downloads`

## What Should Probably Move Off the Mac

Strong candidate to move to `pius` before the Air arrives:

- `~/Documents/archive` (42G)

Likely candidates depending on how active they are:

- large media/video leftovers in `~/Downloads`
- `pdf-translator-experiment` if archival rather than current work
- bulky project artifacts in `Documents` that are no longer active

## What Probably Belongs on the Air

- active personal documents
- active project working trees
- `org`
- `tese`
- selected app state you truly care about keeping local

Examples of app-state decisions that should be explicit:

- browser profiles: migrate only if you want local session/history continuity
- Signal: migrate only if local message history matters on the new machine
- VSCodium/Zed state: migrate only if your editor state is meaningfully curated

## Recommended Budget Target

For a 256GB Air, do not aim to "fit under 256G".

Aim for a comfortable migrated footprint of roughly:

- ideal: under 140G
- acceptable: under 170G
- caution zone: above 180G

That leaves room for:

- macOS itself
- local caches to regrow
- new projects
- swap/headroom

## Best Migration Model

### 1. Rebuild, don’t clone

On the new Air:

- install Nix
- apply this repo’s `darwinConfigurations.air`
- let Homebrew and Nix reconstitute the software layer

This avoids wasting Air storage on:

- old Nix store closures
- stale app bundles
- old Homebrew state

### 2. Migrate only the user layer

After the base system is rebuilt:

- move active documents
- move selected app state
- reconnect Syncthing
- verify the small set of things you really need

### 3. Keep archive remote

Make `pius` the first-class home for:

- archive
- bulk media
- retained historical material

## Safest High-Value Space Wins

These look like the best first moves.

### Easy wins with low emotional cost

- review and clear `~/Downloads`
- clear `~/Library/Caches`
- clear `~/.cache`
- clear Homebrew cache inside `~/Library/Caches/Homebrew`

### Bigger wins if you are comfortable rebuilding

- stop/remove `colima` state from `~/.colima`
- clean unused Julia artifacts
- garbage-collect old Nix store generations

### Structural win

- move `~/Documents/archive` to `pius`

## Manual Checks Still Needed

Because shell visibility was not reliable for protected macOS libraries, check
these in Finder with `Get Info`:

- `~/Pictures/Photos Library.photoslibrary`
- `~/Music/Music`
- `~/Movies/TV`
- `~/Movies/DaVinci Resolve`

Also check:

- Time Machine shows a recent successful backup

## Suggested Order

1. Verify Time Machine freshness
2. Measure Photos/Music/TV/DaVinci libraries in Finder
3. Move `Documents/archive` off the Mac if you agree it belongs on `pius`
4. Clean `Downloads`
5. Clean caches
6. Decide whether `colima`, Julia artifacts, and old Nix generations can be
   rebuilt rather than migrated
7. Re-estimate the "must fit on the Air" footprint

## My Current Read

The current Mac probably becomes quite manageable for a 256GB Air **if** you do
all of the following:

- do not migrate `/nix`
- do not migrate app bundles wholesale
- move `Documents/archive` off the Mac
- clean caches and downloads
- treat `colima` as rebuildable

The one remaining unknown that could still change the picture materially is the
size of the protected Photos/Music/TV/DaVinci libraries.
