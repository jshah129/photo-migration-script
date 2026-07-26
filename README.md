# Photo Migration Script

Flattens a messy photo library into one folder, renames every file by the date it was
actually taken (`YYYYMMDD-NNN`), and quarantines byte-identical duplicates.

PowerShell, no dependencies, Windows only. Built and hardened against a real ~12,000
file / 74 GB library that had accumulated across a decade of phone exports, camera
dumps and re-copies.

**Nothing is ever deleted.** Duplicates are moved to a quarantine folder for you to
review. Every run is reversible.

## Quick start

```powershell
# 1. Scan. Read-only -- writes reports, changes nothing.
.\Migrate-Photos.ps1 -Root "C:\path\to\Pictures"

# 2. Review reports\run-<timestamp>\ (see "What to review" below)

# 3. Apply the plan you just reviewed.
.\Migrate-Photos.ps1 -Execute -PlanPath ".\reports\run-<timestamp>\plan.csv"

# 4. If anything looks wrong, reverse it completely.
.\Undo-Migration.ps1 -ManifestPath ".\reports\run-<timestamp>\manifest.csv"
```

Nothing is destructive until step 3, and step 3 is fully reversible by step 4.

## The problem this solves

Photo libraries rot in a specific way. Files get copied between drives, exported from
phones, re-organised into trip folders, and backed up again. After a few rounds:

- **Filesystem timestamps are worthless.** Every file reports the date of the last
  bulk copy, not the date of the photo.
- **Filenames collide.** Phones recycle `IMG_0001.jpg` endlessly, so the same name
  covers dozens of unrelated photos across folders.
- **The same photo exists many times** under different names, in different folders,
  sometimes in different formats.

Sorting by name or date in Explorer gives you nonsense. This script rebuilds the
library from what the files actually contain.

## How dates are resolved

Timestamps are the *last* thing to trust. The script reads real capture metadata
first and falls back only when it must:

| Priority | Source | Notes |
|---|---|---|
| 1 | EXIF `Date taken` (shell property 12) | Photos. Trusted outright |
| 2 | `Media created` (shell property 214) | Videos. Accepted only if it agrees with the folder's month |
| 3 | Date embedded in filename | e.g. `PXL_20240229_...`, `2024-02-29...` |
| 4 | `LastWriteTime`, if it agrees with the folder's month | Has a real day-of-month, so preferred when plausible |
| 5 | Date encoded in the folder name | Trailing `MMDD` (`Day 3 Roadtrip 0805` → Aug 5) gives an exact day; leading `YYYYMM` (`202206__` → June 2022) defaults the day to the 1st |
| 6 | `LastWriteTime`, when no folder date exists | Rough, but usually the right era |
| 7 | `CreationTime` | Last resort. Flagged as low-confidence |
| — | `Unreliable` | Every source failed. Flagged for manual review |

Every row in `plan.csv` records which source won in its `DateSource` column, so you
can sort by it and check the weak ones before executing.

### Four traps this handles

These were all found by running against real data, and each would have silently
misdated hundreds of files.

**Zeroed metadata parses to the Unix epoch.** Some MOV files carry an empty
`Media created` that reads as `1969-12-31` in a western timezone. Without a floor,
they all get named `19691231-NNN`. Every source is floored at 1990-01-01; below that
the value is discarded and the next source tried.

**Bulk-copy dates masquerade as capture dates.** Hundreds of files landed on a single
date — the day the library was copied, not shot. Folders named `202206__` encode the
true month, so when a timestamp falls *outside* the month its folder claims, the
folder wins; when it falls *inside*, the timestamp is kept because it carries a real
day-of-month.

**Video metadata lies; EXIF does not.** Re-encoded videos share a single
`Media created` stamp — the export time, not the capture time. Measuring the whole
library settled which sources deserve trust: of 3,761 files in month-encoded folders,
239 disagreed with their folder and *every one was `Media created`*. EXIF `Date taken`
never disagreed once. So the folder cross-check is applied to `Media created` and
deliberately withheld from EXIF.

**Trip folders name their own day.** `Day 3 Roadtrip 0805` means Aug 5, so a rejected
video timestamp still resolves to the right day rather than the 1st of the month. The
trailing `MMDD` needs a year from elsewhere — the discarded metadata is wrong about
the day but right about the year. Folders ending in a bare year (`Trip 2023`) are
correctly ignored, because 20 is not a month. The search walks up to three parent
levels, since curated subfolders (`Day 3 Roadtrip 0805\Selected Media`) name no date
of their own, and stops at the library root.

### Not everything odd is an artifact

A folder where 316 photos all share one date looks exactly like a bulk-copy
signature. But if their times span 06:11–23:59 with a spike at 23:00, and the folder
also holds the following two days, that is a real New Year's trip. The distinction is
time-of-day spread: artifacts collapse into a handful of identical stamps, real days
do not. The script leaves these alone.

> EXIF times are camera-local; Google's `PXL_` filenames are UTC. A photo taken at
> 7pm on 2/28 local becomes `PXL_20240229_...`. EXIF wins, which is correct — the
> file is named for the day you actually took it.

## How duplicates are handled

Dedup is **content-based (SHA-256), never name-based.** This matters in both
directions:

- **Same bytes, different names** → genuine duplicates. One copy is kept, the rest
  move to quarantine. Two files are the same photo regardless of what they're called.
- **Same name, different bytes** → *not* duplicates. A typical library has hundreds of
  repeated filenames. Name-matching would silently destroy distinct photos.
  **Every distinct image survives**, and the date-based rename gives each a unique
  name. They're listed in `same-name-different-photo.csv`.

This is a guarantee about *images*, not *files*. One name can cover three files that
are only two distinct photos — two byte-identical, one different. The redundant copy
is still quarantined; both real photos survive:

| Path | Image | Action |
|---|---|---|
| `Camera Roll\IMG_0213.JPG` | `A13988E3…` | Keep |
| `Phone\201711__\IMG_0213.JPG` | `A13988E3…` | Quarantine |
| `Phone\202204__\IMG_0213.JPG` | `0BBB0934…` | Keep |

Verified as an invariant across every shared name in the test library: files kept
always equals distinct images, zero violations. Nothing visually unique is ever
quarantined.

When choosing which copy of a duplicate set to keep, the script prefers the one with
the most trustworthy date source, then the shallowest path, then alphabetical order —
so results are identical across runs.

**Sidecars are exempt from dedup.** Apple writes byte-identical `.AAE` edit sidecars
for unrelated photos; hashing them would delete legitimate edit data. They're matched
to their photo by name instead.

## Naming

`YYYYMMDD-NNN.ext` — e.g. `20250804-001.jpg`, `20250804-002.jpg`.

Year-first so a plain filename sort is chronological, and zero-padded to three digits
so `-002` does not sort after `-010`. Both matter: without padding, any day holding
ten or more files orders wrongly within itself.

`NNN` restarts each calendar day and runs in **chronological order within that day**,
so `-001`, `-002`, `-003` is the order the shots were actually taken.

**A trailing label is preserved.** Rename a file to `20231221-001-BeachTrip.mp4` and
later runs leave it alone, so you can annotate favourites without breaking anything.

**Live Photo and sidecar sets stay together.** Files sharing a folder and base name
(`IMG_1234.HEIC` + `IMG_1234.MOV` + `IMG_1234.AAE`) get the *same* number with their
own extensions:

```
20250804-007.heic
20250804-007.mov
20250804-007.aae
```

Pass `-NoPairGrouping` to give every file its own number instead.

## Adding new photos later (`-Incremental`)

Once a library is migrated, **never re-run the plain scan over it.** Sequence numbers
are assigned by sorting within each day with the file path as tiebreaker. Migrated
files have new paths, so a second plain run reshuffles the numbering and renames
thousands of files for nothing.

`-Incremental` treats any root file under a `YYYYMMDD-NNN` name as *settled*:

- **Never renamed, renumbered, or moved.** They appear in the plan as `Skip`.
- **Each day's numbering resumes from its high-water mark.** A new photo from a day
  that already ends at `-003` becomes `-004`, not a collision.
- **Settled copies win duplicate contests.** Re-importing a photo you already have
  quarantines the *new* copy and leaves the one already in place.

The routine for every future import:

```powershell
# 1. Copy from the phone into a staging folder inside the library.
#    Copy, don't move -- leave the originals on the phone until you have verified.

# 2. Audit. Read-only; re-hashes the whole library to catch duplicates.
.\Migrate-Photos.ps1 -Incremental

# 3. Find same-photo-different-format pairs. Pass EVERY prior run's plan --
#    each import adds a generation of settled files that needs resolving.
.\Find-NearDuplicates.ps1 -PlanPath ".\reports\run-<new>\plan.csv" `
    -HistoryPlanPath @(".\reports\run-<new>\plan.csv", ".\reports\run-<older>\plan.csv")

# 4. Check "Already migrated, untouched" matches your current root file count,
#    then review plan.csv, duplicates.csv and possible-duplicates.csv.

# 5. Apply.
.\Migrate-Photos.ps1 -Execute -PlanPath ".\reports\run-<new>\plan.csv"

# 6. Clear the emptied import folders yourself.
```

Two things to know about repeating this:

- **Step 3's history list grows by one entry per import.** Miss one and the script
  reports fewer pairs rather than failing, so check the "Recovered N camera filenames
  from M history plan(s)" line it prints.
- **Every run re-hashes the whole library**, so audits get slower as it grows:
  roughly a minute per 12 GB. Only the audit is affected; applying a plan stays fast
  because moves within a drive are instant.

Keep every `reports\run-*` folder. They carry the undo manifests and the camera-name
history, and both are needed later.

Duplicates against the quarantine folder need no special handling: quarantine is
excluded from scanning, but every quarantined file is byte-identical to one that
stayed in the root, so an incoming copy still matches.

## Same photo, different format (`Find-NearDuplicates.ps1`)

Importing from an iPhone with "Automatic" conversion leaves you holding the HEIC
original *and* a JPEG of the same shot. They share no bytes, so SHA-256 correctly
refuses to call them duplicates and both are kept. This script finds them.

```powershell
.\Find-NearDuplicates.ps1 -PlanPath        ".\reports\run-B\plan.csv" `
                          -HistoryPlanPath ".\reports\run-A\plan.csv" `
                          -RenameMapPath   ".\reports\run-A\rename-map.csv"
```

A pair is reported only when the camera filenames share a stem (`IMG_7533`), the
capture instants match, both files are stills, and the formats differ. All four
conditions are needed:

- **Stem alone is unsafe** — phones recycle `IMG_####` numbers across years.
- **Capture time alone is far too loose** — Windows exposes `Date taken` only to the
  minute, so a burst of shots shares one timestamp. Matching on time alone produced
  7,186 files in testing, almost all false; adding the stem cut it to 196.
- **Stills only** — a HEIC and a MOV a second apart is a Live Photo, not a duplicate.

Already-migrated files no longer carry their camera filename, so `-HistoryPlanPath`
recovers it from the runs that renamed them. If they were renamed *again* after a
plan was written, `-RenameMapPath` bridges the gap: current → old → camera name.
Both parameters accept lists. Without the full chain the script silently finds
nothing, so check the counts it prints when it starts.

Apple's edited renditions (`IMG_E7533`) are tracked as a separate stem from the
original — an edit is a genuinely different image.

The script only reports. Which format to keep is a judgement call: HEIC is the
original at about half the size, JPEG is larger, slightly lossy, and opens anywhere.

## What to review after a scan

`reports\run-<timestamp>\`

| File | What it tells you |
|---|---|
| `plan.csv` | Every planned action: source, destination, new name, capture date, date source |
| `duplicates.csv` | Each quarantined copy paired with the twin kept in its place — original paths, post-migration names, size, shared hash. Sorted largest first |
| `same-name-different-photo.csv` | Files sharing a name that cover genuinely different photos. Every distinct image is kept; byte-identical twins within the group are still quarantined |
| `possible-duplicates.csv` | Written by `Find-NearDuplicates.ps1`. Same photo in two formats |
| `ignored-files.csv` | Non-media files left untouched where they are |
| `manifest.csv` | Written by `-Execute`. Feeds `Undo-Migration.ps1` |

Worth checking before executing:

1. The **low-confidence date count** in the summary. If non-zero, filter `plan.csv`
   for `DateSource = CreationTime` and spot-check those.
2. A few rows in `duplicates.csv` — confirm the kept copy is the one you'd want.
   Because matches are byte-identical, both files are the same image and the choice
   only affects which folder it came from. To verify a pair with a tool other than
   this script: `fc /b "<KeptPath>" "<DuplicatePath>"`, Windows' own byte comparator.
3. The scale of `same-name-different-photo.csv`, to confirm nothing collapsed that
   shouldn't have.

## Safety

- **Two-pass by design.** The scan cannot modify anything; execution only replays a
  CSV you have already read.
- **Nothing is deleted, ever.** Duplicates are quarantined, not removed.
- **Nothing is overwritten.** If a destination is occupied, the file gets a `_dup1`
  suffix and a warning rather than clobbering.
- **Fully reversible** via `Undo-Migration.ps1`, which restores original paths and
  recreates the original folder tree. Verified as a byte-for-byte round-trip.
- **Empty folders are reported, not deleted.** The script prints the cleanup command
  so the decision stays yours.
- **Plans carry their own root**, so applying one against the wrong `-Root` warns and
  self-corrects instead of acting on the wrong library.
- `-CopyInstead` duplicates rather than moves, leaving the original tree intact.
  Needs a second copy's worth of disk.

## Parameters

### `Migrate-Photos.ps1`

| Parameter | Default | Purpose |
|---|---|---|
| `-Root` | `%USERPROFILE%\Pictures` | Library root. Files are gathered recursively and land back here |
| `-Execute` | off | Apply a plan. Requires `-PlanPath` |
| `-PlanPath` | — | The reviewed `plan.csv` to apply |
| `-Incremental` | off | Adding to an already-migrated library. Leaves settled files untouched |
| `-CopyInstead` | off | Copy instead of move |
| `-NoPairGrouping` | off | Don't keep Live Photo / sidecar sets on one number |
| `-QuarantineName` | `_DuplicatesQuarantine` | Duplicate folder name, created under `-Root` |
| `-ReportRoot` | `.\reports` | Where run artifacts go. Kept outside the library by default |

### `Find-NearDuplicates.ps1`

| Parameter | Purpose |
|---|---|
| `-PlanPath` | The plan to analyse (required) |
| `-HistoryPlanPath` | Prior run plans, for recovering camera filenames. Accepts a list |
| `-RenameMapPath` | Rename logs (`Old`,`New` CSV) if files were renamed after a plan was written. Accepts a list |
| `-OutputPath` | Report destination. Defaults to the plan's folder |

### `Undo-Migration.ps1`

| Parameter | Purpose |
|---|---|
| `-ManifestPath` | The manifest to reverse (required). Supports `-WhatIf` |

## Testing

Verified end-to-end on sandboxes seeded with real photos plus deliberately planted
exact duplicates and name-collisions-with-different-content:

- Flatten/rename/quarantine produced exactly the planted duplicates, no others
- Unique SHA-256 count identical before and after — no unique image lost
- Undo restored every file to its original path and folder structure
- Incremental mode left settled files untouched, continued day numbering correctly,
  and made settled copies win duplicate contests
- The folder-date parser is unit-tested against 15 real folder-name shapes,
  including ones that must *not* parse

Hashing throughput measured at ~219 MB/s.

## Notes

- Requires Windows PowerShell 5.1+ (uses `Shell.Application` COM for metadata).
- If script execution is blocked:
  `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`
- Keep the `reports\` folder until you're satisfied — it's the only way to undo.
- `reports\` is gitignored: it contains the full paths and filenames of your library.

## Licence

MIT
