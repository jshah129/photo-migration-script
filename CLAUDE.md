# photomigration-script

PowerShell tooling that flattens, renames, and de-duplicates a large photo library
under `C:\Users\joysh\Pictures`.

## Scripts

| Script | Purpose |
|---|---|
| `Migrate-Photos.ps1` | The main pass — flatten, rename, dedupe |
| `Find-NearDuplicates.ps1` | Perceptual near-duplicate detection |
| `Undo-Migration.ps1` | Reverses a run using its report |

`reports/` holds dated run outputs (CSV) plus `library-index.csv`. These are
generated artifacts — regenerable, safe to delete, and not worth reviewing as source.

## The one thing to know

**Filesystem timestamps in this library are not trustworthy.** `CreationTime` and
`LastWriteTime` were rewritten by past copies and cloud sync, so they do not reflect
when a photo was taken.

Use the **Windows Shell extended properties instead — property 12 (Date taken) and
property 214 (Media created)** — with the filesystem timestamp only as a last-resort
fallback. Any new date logic must follow the same order, or photos get filed under
the year they were copied rather than the year they were shot.

## Safety

This script moves and deletes real, irreplaceable files. Anything that changes its
matching or deletion logic must be dry-run against a copy first, and `Undo-Migration.ps1`
must stay in sync with whatever `Migrate-Photos.ps1` writes to its report.
