# iPhone Photo Backup for Windows

Back your iPhone photos up to a Windows PC and end up with a library you can
actually navigate: one folder, every file named for the date it was taken, and no
duplicates.

```
IMG_7533.HEIC   ->   20231008-001.heic
IMG_7534.HEIC   ->   20231008-002.heic
IMG_7534.MOV    ->   20231008-002.mov     (Live Photo, kept paired)
```

Sort by filename and you are sorting by time. Plug the phone in again next month and
run it again; it only touches the new arrivals.

PowerShell 5.1+, no dependencies, no cloud, no account. **Nothing is ever deleted** —
duplicates move to a quarantine folder for you to review — and every run is
reversible.

## Why this is needed

Copying photos off an iPhone gives you folders like `100APPLE` full of `IMG_0001.HEIC`,
and the problems start immediately:

- **Filenames are meaningless and collide.** iPhones recycle `IMG_0001` endlessly, so
  the same name covers unrelated photos across folders and across imports.
- **File timestamps are wrong.** Copying sets them to the copy date, not the day you
  took the photo. Sorting by "date modified" sorts by when you plugged the cable in.
- **You import the same photos repeatedly.** Every import overlaps the last, and
  Windows will happily keep `IMG_0001 (2).HEIC` forever.
- **Windows silently converts HEIC to JPEG** on import unless you change a setting, so
  the same photo ends up stored twice in two formats that share no bytes.

This handles all four.

## Getting started

Copy photos off your iPhone however you like — Windows' *Import pictures and videos*,
dragging `DCIM` folders out of File Explorer, or an existing pile you already have.
Drop them anywhere inside your Pictures folder. The layout does not matter; nested
subfolders are fine.

```powershell
# 1. Look, don't touch. Read-only: writes a plan, changes nothing.
.\Migrate-Photos.ps1

# 2. Read reports\run-<timestamp>\plan.csv -- every rename it intends to do.

# 3. Do it.
.\Migrate-Photos.ps1 -Execute -PlanPath ".\reports\run-<timestamp>\plan.csv"

# 4. Changed your mind? Put everything back exactly as it was.
.\Undo-Migration.ps1 -ManifestPath ".\reports\run-<timestamp>\manifest.csv"
```

Point it elsewhere with `-Root "D:\Photos"`. Nothing is modified until step 3, and
step 3 is fully reversible by step 4.

**Every import after the first:** add `-Incremental` so files already sorted are left
alone. See [Adding more photos later](#adding-more-photos-later).

## How dates are worked out

File timestamps are the *last* thing to trust, so real capture metadata is read first:

| Priority | Source | Notes |
|---|---|---|
| 1 | EXIF `Date taken` | Photos. Trusted outright |
| 2 | `Media created` | Videos. Accepted only if it agrees with the folder's month |
| 3 | Date embedded in the filename | Screenshots, WhatsApp saves, `PXL_20240229_...` |
| 4 | `LastWriteTime`, if it agrees with the folder's month | Carries a real day-of-month |
| 5 | Month from a `YYYYMM` folder name | Day defaults to the 1st |
| 6 | `LastWriteTime` | Rough, but usually the right era |
| 7 | `CreationTime` | Last resort. Flagged as low-confidence |
| — | `Unreliable` | Everything failed. Flagged for manual review |

Every row in `plan.csv` records which source won, in its `DateSource` column. Sort by
it and spot-check anything below priority 3 before you execute.

Implausible dates are rejected rather than used — a video carrying an empty timestamp
that reads as 1969 falls through to the next source instead of landing under
`19691231-NNN`.

## How duplicates are handled

Deduplication is **content-based (SHA-256), never name-based** — which matters in both
directions:

- **Same bytes, different names** → genuine duplicates. One copy is kept; the rest move
  to quarantine.
- **Same name, different bytes** → *not* duplicates. Because iPhones recycle `IMG_0001`,
  name-matching would silently destroy unrelated photos. **Every distinct image
  survives.** They are listed in `same-name-different-photo.csv`.

That guarantee is about *images*, not *files*. One name can cover three files that are
only two distinct photos — two byte-identical, one different. The redundant copy is
still quarantined; both real photos survive:

| File | Image | Action |
|---|---|---|
| `100APPLE\IMG_0213.JPG` | `A13988E3…` | Keep |
| `101APPLE\IMG_0213.JPG` | `A13988E3…` | Quarantine |
| `102APPLE\IMG_0213.JPG` | `0BBB0934…` | Keep |

Files kept always equals distinct images. Nothing visually unique is ever quarantined.

Where several copies are identical, the one with the most trustworthy date wins, then
the shallowest path, then alphabetical order — so runs are repeatable.

**`.AAE` sidecars are exempt from deduplication.** Apple writes byte-identical edit
sidecars for unrelated photos, so hashing them would throw away real edit data. They
are matched to their photo by name instead.

## Naming

`YYYYMMDD-NNN.ext` — `20250804-001.jpg`, `20250804-002.jpg`.

Year-first so a filename sort is chronological, and zero-padded to three digits so
`-002` does not sort after `-010`. `NNN` restarts each day and follows the order the
shots were actually taken.

**Live Photos stay paired.** The HEIC and its MOV share a base name, so they get the
same number and stay together:

```
20250804-007.heic
20250804-007.mov
20250804-007.aae
```

Use `-NoPairGrouping` to number every file separately.

**Labels are preserved.** Rename a file to `20250804-007-Birthday.heic` and later runs
leave it alone, so you can annotate favourites without breaking anything.

## Adding more photos later

Copy the new photos in, then run with `-Incremental`. Files already carrying a
`YYYYMMDD-NNN` name in the library root are treated as *settled*:

- **Never renamed, renumbered or moved.** They show as `Skip` in the plan.
- **Numbering continues.** A new photo from a day that already ends at `-003` becomes
  `-004`.
- **The copy you already have wins.** Re-importing a photo you already filed
  quarantines the *new* copy, not the settled one.

```powershell
# 1. Copy new photos into the library. Copy, don't move -- leave the
#    originals on the phone until you have checked the result.

# 2. Audit.
.\Migrate-Photos.ps1 -Incremental

# 3. Optional: find the same photo saved as both HEIC and JPEG.
.\Find-NearDuplicates.ps1 -PlanPath ".\reports\run-<timestamp>\plan.csv"

# 4. Check "Already migrated, untouched" matches your current file count,
#    then read plan.csv and duplicates.csv.

# 5. Apply.
.\Migrate-Photos.ps1 -Execute -PlanPath ".\reports\run-<timestamp>\plan.csv"
```

> **Always use `-Incremental` on a library you have already migrated.** Without it,
> numbering is recalculated from scratch and thousands of already-sorted files get
> renamed for no reason.

Every run re-hashes the whole library to catch duplicates, so audits get slower as it
grows — roughly a minute per 12 GB. Only the audit is affected; applying a plan is
fast, because moving files within a drive is instant.

Quarantined duplicates need no special handling on later runs: quarantine is skipped
during scanning, but every file in it is byte-identical to one still in the library,
so an incoming copy still matches.

## Same photo, HEIC and JPEG

Windows converts HEIC to JPEG on import unless you set *Keep Originals*. Import once
each way — or on two PCs — and you hold both renditions of the same photo. They share
no bytes, so they are not duplicates in any technical sense.

**Both are kept, and that is the right default.** HEIC is the original at about half
the size; JPEG opens anywhere without conversion. Neither can be regenerated from the
other, and the overlap is typically a fraction of a percent of the library — not worth
the risk of throwing one away.

If you want to see them anyway:

```powershell
.\Find-NearDuplicates.ps1 -PlanPath ".\reports\run-<timestamp>\plan.csv"
```

This writes `possible-duplicates.csv` listing each pair with both filenames, formats
and sizes. It only reports — there is no option to act on it. If you decide you want
only one format, move those files to the quarantine folder yourself using the
filenames in the CSV.

Pairs are matched on the camera filename stem plus the capture instant together;
either alone is unreliable, since iPhones recycle `IMG_####` numbers and Windows
exposes `Date taken` only to the minute. Live Photo video halves are excluded, and
Apple's edited renditions (`IMG_E7533`) count as separate photos.

Once a file is renamed, nothing on disk remembers it arrived as `IMG_7533.HEIC`, so
`Migrate-Photos.ps1` records that in `reports\library-index.csv` as it goes. The
script reads it automatically; there is nothing to pass or maintain.

## What the reports tell you

`reports\run-<timestamp>\`

| File | Contents |
|---|---|
| `plan.csv` | Every planned action: source, destination, new name, capture date, date source |
| `duplicates.csv` | Each quarantined copy paired with the twin kept in its place. Sorted largest first |
| `same-name-different-photo.csv` | Files sharing a name that are genuinely different photos |
| `possible-duplicates.csv` | From `Find-NearDuplicates.ps1`: the same photo in two formats |
| `ignored-files.csv` | Non-media files, left where they are |
| `manifest.csv` | Written by `-Execute`. Feeds `Undo-Migration.ps1` |

`reports\library-index.csv` sits alongside them and accumulates across runs.

Before executing, three things are worth a look:

1. The **low-confidence date count** in the summary. If it is not zero, filter
   `plan.csv` by `DateSource` and spot-check.
2. A few rows of `duplicates.csv`. Matches are byte-identical, so both files are the
   same image and the choice only affects which folder it came from. Verify a pair
   independently with `fc /b "<KeptPath>" "<DuplicatePath>"`.
3. The size of `same-name-different-photo.csv`, to confirm nothing collapsed that
   shouldn't have.

## Safety

- **Two passes.** The scan cannot modify anything; execution only replays a CSV you
  have read.
- **Nothing is deleted, ever.** Duplicates are quarantined, not removed. Emptied
  folders are reported, not deleted — the script prints the cleanup command and leaves
  the decision to you.
- **Nothing is overwritten.** An occupied destination gets a `_dup1` suffix and a
  warning.
- **Fully reversible.** `Undo-Migration.ps1` restores original paths and recreates the
  original folder tree.
- **Plans know their own library**, so applying one against the wrong `-Root` warns and
  corrects itself rather than acting on the wrong folder.
- `-CopyInstead` copies instead of moving, leaving the source tree untouched. Needs
  room for a second copy.

Keep the `reports\` folder. It holds the undo manifests and the camera-name index.

## Parameters

### `Migrate-Photos.ps1`

| Parameter | Default | Purpose |
|---|---|---|
| `-Root` | `%USERPROFILE%\Pictures` | Library root. Scanned recursively; files land back here |
| `-Execute` | off | Apply a plan. Requires `-PlanPath` |
| `-PlanPath` | — | The reviewed `plan.csv` to apply |
| `-Incremental` | off | Adding to an already-migrated library. Leaves settled files untouched |
| `-CopyInstead` | off | Copy instead of move |
| `-NoPairGrouping` | off | Number Live Photo / sidecar sets separately |
| `-QuarantineName` | `_DuplicatesQuarantine` | Quarantine folder, created under `-Root` |
| `-ReportRoot` | `.\reports` | Where run artifacts go. Outside the library by default |

### `Find-NearDuplicates.ps1`

| Parameter | Purpose |
|---|---|
| `-PlanPath` | The plan to analyse (required) |
| `-IndexPath` | Camera-name index. Found automatically beside the plan |
| `-OutputPath` | Report destination. Defaults to the plan's folder |

### `Undo-Migration.ps1`

| Parameter | Purpose |
|---|---|
| `-ManifestPath` | The manifest to reverse (required). Supports `-WhatIf` |

## Supported files

Photos `.jpg .jpeg .png .heic .heif .gif .bmp .webp .tif .tiff`, raw
`.dng .raw .cr2 .cr3 .nef .arw .orf .rw2`, video
`.mov .mp4 .m4v .avi .mkv .3gp .mpg .mpeg .wmv`, sidecars `.aae .xmp .thm`.

Anything else is listed in `ignored-files.csv` and left exactly where it is.

## Testing

Verified end-to-end on sandboxes seeded with real photos plus deliberately planted
exact duplicates and name-collisions-with-different-content:

- Flatten, rename and quarantine produced exactly the planted duplicates and no others
- Unique SHA-256 count identical before and after — no unique image lost
- Undo restored every file to its original path and folder structure
- Incremental mode left settled files untouched, continued numbering correctly, and
  made settled copies win duplicate contests
- The folder-date parser is unit-tested against folder names that must parse and
  names that must not

## Notes

- Windows only: reads photo metadata through `Shell.Application` COM.
- If script execution is blocked:
  `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`
- `reports\` is gitignored. It contains the paths and filenames of your library.

## A note on how this was built

This project — the scripts as well as this README — was written with the assistance
of AI, working against a real photo library rather than a synthetic one. Most of the
behaviour documented above exists because a scan of that library turned up something
the first attempt got wrong.

It has been tested end to end, but it moves your files. Run the read-only scan first,
read `plan.csv`, and keep the `reports\` folder until you are satisfied — that is the
only route back.

## Licence

MIT
