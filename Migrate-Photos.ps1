<#
.SYNOPSIS
  Flattens a photo library into its root folder, renames files by capture date
  (YYYYMMDD-NNN), and quarantines byte-identical duplicates.

.DESCRIPTION
  Runs in two passes:

    PASS 1 (default, read-only) -- scans, hashes, resolves dates, and writes a
      plan CSV plus duplicate/conflict reports. Changes nothing on disk.

    PASS 2 (-Execute) -- replays the plan CSV. Moves (or copies) each file to
      the root under its new name, and moves duplicates to a quarantine folder.
      Writes a manifest that Undo-Migration.ps1 can reverse.

  Date resolution order (first hit wins):
    1. EXIF "Date taken"   (shell property 12)  -- photos, trusted outright
    2. "Media created"     (shell property 214) -- videos, only if it agrees with
                                                   the month the folder claims
    3. Date embedded in the original filename   -- e.g. PXL_20240229_...
    4. LastWriteTime, when it agrees with the folder's month (it has a real day)
    5. Month encoded in the folder name         -- leading YYYYMM, e.g. "202310_a"
    6. LastWriteTime, when no folder month exists
    7. CreationTime (last resort; often a bulk-copy date and untrustworthy)

  Every source is floored at 1990-01-01, because some files carry a zeroed date
  that parses to the Unix epoch.

.EXAMPLE
  .\Migrate-Photos.ps1
  Dry run against the default root. Review reports\ afterwards.

.EXAMPLE
  .\Migrate-Photos.ps1 -Execute -PlanPath .\reports\run-20260726-101500\plan.csv
  Applies a plan you have reviewed.
#>
[CmdletBinding()]
param(
    # Library root. Files are gathered from here recursively and land back here.
    [string] $Root = (Join-Path $env:USERPROFILE 'Pictures'),

    # Apply a plan. Without this the script only scans and reports.
    [switch] $Execute,

    # Plan CSV to apply. Required with -Execute.
    [string] $PlanPath,

    # Copy instead of move. Safer, but needs room for a second copy of the library.
    [switch] $CopyInstead,

    # Give each file its own sequence number instead of keeping Live Photo /
    # sidecar sets (IMG_1234.HEIC + IMG_1234.MOV + IMG_1234.AAE) on one number.
    [switch] $NoPairGrouping,

    # Folder (under Root) that byte-identical duplicates are moved into.
    [string] $QuarantineName = "_DuplicatesQuarantine",

    # Adding to an already-migrated library. Files sitting in the root that already
    # carry a YYYYMMDD-NNN name are left exactly as they are: not renamed, not
    # renumbered, not moved. New arrivals continue each day's numbering from where
    # it left off, and when a new file duplicates a settled one the settled copy
    # always wins. Without this, a second run reshuffles the whole library.
    [switch] $Incremental,

    # Where run artifacts are written. Defaults to .\reports next to this script.
    [string] $ReportRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

# Files that get renamed, hashed and deduplicated.
$MediaExtensions = @(
    '.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.gif', '.bmp', '.webp',
    '.heic', '.heif', '.tif', '.tiff',
    '.dng', '.raw', '.cr2', '.cr3', '.nef', '.arw', '.orf', '.rw2',
    '.mov', '.mp4', '.m4v', '.avi', '.mkv', '.3gp', '.mpg', '.mpeg', '.wmv'
)

# Companion files. They travel with their media file and are renamed to match,
# but are never content-deduplicated: Apple writes byte-identical .AAE sidecars
# for unrelated photos, so hashing them would delete legitimate edit data.
$SidecarExtensions = @('.aae', '.xmp', '.thm')

# A file already carrying the output naming scheme, e.g. "20250804-007".
# A trailing label is allowed and preserved -- "20231221-001-BeachTrip" stays exactly
# as it is, so hand-annotated names survive later incremental runs.
$SettledNamePattern = '^\d{8}-\d{3}(-.+)?$'

# Shell property indices. 214 is "Media created"; 208 returns "Unresolved".
$PROP_DATE_TAKEN    = 12
$PROP_MEDIA_CREATED = 214

# Sanity floor for every date source. Some MOV files carry a zeroed "Media
# created" that parses to the Unix epoch (1969-12-31 in a western timezone);
# without this those files would all be named 19691231-NNN. Anything below the
# floor is discarded and the next source is tried.
$MinPlausibleDate = [datetime]'1990-01-01'

# Filename date patterns, tried in order. Group names y/m/d are required.
$FilenameDatePatterns = @(
    '(?<y>19\d{2}|20\d{2})(?<m>0[1-9]|1[0-2])(?<d>0[1-9]|[12]\d|3[01])',        # 20240229
    '(?<y>19\d{2}|20\d{2})[-_.](?<m>0[1-9]|1[0-2])[-_.](?<d>0[1-9]|[12]\d|3[01])' # 2024-02-29
)

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

function Write-Section {
    param([string] $Text)
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

<#
  Shell.Application returns date strings padded with Unicode bidirectional
  marks (U+200E / U+200F). Left in place they break [datetime]::Parse.
#>
function ConvertFrom-ShellDate {
    param([string] $Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }

    $clean = ($Raw -replace "[\u200e\u200f\u202a-\u202e]", '').Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { return $null }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($clean, [ref] $parsed)) { return $parsed }
    return $null
}

<#
  Phone exports commonly name folders by the month they cover -- "202206__",
  "202310_a" -- and that beats a file timestamp flattened to a bulk-copy date.

  Only a leading YYYYMM is accepted. Digits elsewhere in a folder name are not
  treated as dates: "Project 1204" and "Invoice 0315" are not December 4th and
  March 15th, and guessing otherwise misdates files silently.

  Returns the first of the encoded month, or $null.
#>
function Get-FolderMonthHint {
    param([string] $FolderName)

    $m = [regex]::Match($FolderName, '^(?<y>19\d{2}|20\d{2})(?<m>0[1-9]|1[0-2])(?:[^\d]|$)')
    if (-not $m.Success) { return $null }

    $y = [int] $m.Groups['y'].Value
    if ($y -lt 1990 -or $y -gt (Get-Date).Year + 1) { return $null }

    return [datetime]::new($y, [int] $m.Groups['m'].Value, 1)
}

function Get-DateFromFilename {
    param([string] $Name)

    foreach ($pattern in $FilenameDatePatterns) {
        $m = [regex]::Match($Name, $pattern)
        if (-not $m.Success) { continue }

        $y = [int] $m.Groups['y'].Value
        $mo = [int] $m.Groups['m'].Value
        $d = [int] $m.Groups['d'].Value

        # Reject dates that cannot be real photos (bad regex hit on a serial number).
        if ($y -lt 1990 -or $y -gt (Get-Date).Year + 1) { continue }
        if ($d -gt [datetime]::DaysInMonth($y, $mo)) { continue }

        return [datetime]::new($y, $mo, $d)
    }
    return $null
}

<#
  Resolves capture date for one file, returning the date and which source won
  so the plan can show its own confidence.
#>
function Resolve-CaptureDate {
    param(
        [System.IO.FileInfo] $File,
        $ShellFolder
    )

    $taken = $null
    $created = $null
    if ($null -ne $ShellFolder) {
        $item = $ShellFolder.ParseName($File.Name)
        if ($null -ne $item) {
            $taken = ConvertFrom-ShellDate $ShellFolder.GetDetailsOf($item, $PROP_DATE_TAKEN)
            $created = ConvertFrom-ShellDate $ShellFolder.GetDetailsOf($item, $PROP_MEDIA_CREATED)
        }
    }
    if ($null -ne $taken -and $taken -lt $MinPlausibleDate) { $taken = $null }
    if ($null -ne $created -and $created -lt $MinPlausibleDate) { $created = $null }

    # EXIF "Date taken" is trusted outright. Measured across a full library it never
    # once disagreed with the month its folder claimed.
    if ($null -ne $taken) {
        return [PSCustomObject]@{ Date = $taken; Source = 'ExifDateTaken' }
    }

    $writeOk = $File.LastWriteTime -ge $MinPlausibleDate

    # Curated subfolders carry no date of their own -- "202310_a\Selected Media" is
    # dated by its parent, not its leaf. Walk up until a folder names a month,
    # stopping at the library root so folders outside it are never consulted.
    $folder = $null
    $probe = $File.Directory
    for ($hop = 0; $hop -lt 3 -and $null -ne $probe; $hop++) {
        if ($probe.FullName.TrimEnd('\') -eq $Root.TrimEnd('\')) { break }
        $folder = Get-FolderMonthHint -FolderName $probe.Name
        if ($null -ne $folder) { break }
        $probe = $probe.Parent
    }

    # "Media created" is not trustworthy on its own: re-encoded videos share a single
    # stamp recording when they were exported rather than shot. Accept it only when it
    # agrees with the month the folder claims.
    if ($null -ne $created) {
        if ($null -eq $folder -or
            ($created.Year -eq $folder.Year -and $created.Month -eq $folder.Month)) {
            return [PSCustomObject]@{ Date = $created; Source = 'MediaCreated' }
        }
    }

    $fromName = Get-DateFromFilename $File.BaseName
    if ($null -ne $fromName) {
        return [PSCustomObject]@{ Date = $fromName; Source = 'Filename' }
    }

    # A timestamp inside the folder's month is probably genuine and carries a real
    # day-of-month, so prefer it. Outside, it is a bulk-copy artifact and the folder
    # wins -- though the folder knows only the month, so the day defaults to the 1st.
    if ($null -ne $folder) {
        if ($writeOk -and
            $File.LastWriteTime.Year -eq $folder.Year -and
            $File.LastWriteTime.Month -eq $folder.Month) {
            return [PSCustomObject]@{ Date = $File.LastWriteTime; Source = 'LastWriteTime' }
        }
        return [PSCustomObject]@{ Date = $folder; Source = 'FolderMonth' }
    }

    if ($writeOk) {
        return [PSCustomObject]@{ Date = $File.LastWriteTime; Source = 'LastWriteTime' }
    }

    if ($File.CreationTime -ge $MinPlausibleDate) {
        return [PSCustomObject]@{ Date = $File.CreationTime; Source = 'CreationTime' }
    }

    # Every source was missing or implausible. Use the least-bad value but flag it
    # loudly so these files get looked at by hand rather than silently misnamed.
    return [PSCustomObject]@{ Date = $File.LastWriteTime; Source = 'Unreliable' }
}

<#
  Picks which copy of a set of byte-identical files to keep. Prefers a trustworthy
  date source, then the shallowest path, then alphabetical for determinism.
#>
function Get-KeeperRank {
    param($Entry)

    # An already-migrated file always outranks a fresh arrival, so re-importing a
    # photo you already have quarantines the new copy rather than the settled one.
    $settledRank = if ($Entry.IsSettled) { 0 } else { 1 }

    $sourceRank = switch ($Entry.DateSource) {
        'ExifDateTaken' { 0 }
        'MediaCreated'  { 0 }
        'Filename'      { 1 }
        'LastWriteTime' { 2 }
        'FolderMonth'   { 3 }
        default         { 4 }
    }
    return "{0}|{1}|{2:d3}|{3}" -f $settledRank, $sourceRank, $Entry.Depth, $Entry.FullName.ToLowerInvariant()
}

function New-UniqueDestination {
    param(
        [string] $Directory,
        [string] $DesiredName,
        [System.Collections.Generic.HashSet[string]] $Claimed
    )

    $base = [System.IO.Path]::GetFileNameWithoutExtension($DesiredName)
    $ext = [System.IO.Path]::GetExtension($DesiredName)
    $candidate = $DesiredName
    $suffix = 1

    while ($Claimed.Contains($candidate.ToLowerInvariant()) -or
           (Test-Path -LiteralPath (Join-Path $Directory $candidate))) {
        $candidate = "{0}_{1}{2}" -f $base, $suffix, $ext
        $suffix++
    }

    [void] $Claimed.Add($candidate.ToLowerInvariant())
    return $candidate
}

<#
  Maintains reports\library-index.csv: the camera filename each file arrived with,
  keyed by the name it now carries in the library.

  Once a file is renamed to 20250804-007.heic, nothing on disk remembers it used to
  be IMG_7533.HEIC -- and Find-NearDuplicates.ps1 needs that to spot the same shot
  saved as both HEIC and JPEG. Accumulating it here, one row per file, means later
  runs never have to be handed a list of previous runs.
#>
function Update-LibraryIndex {
    param(
        [string] $RunDir,
        [System.Collections.Generic.List[object]] $Additions
    )

    if ($Additions.Count -eq 0) { return }

    # One directory above the per-run folder, so it survives across runs.
    $indexPath = Join-Path (Split-Path -Parent $RunDir) 'library-index.csv'

    $merged = [ordered]@{}
    if (Test-Path -LiteralPath $indexPath) {
        foreach ($row in (Import-Csv -LiteralPath $indexPath)) {
            $merged[$row.Name] = $row
        }
    }
    foreach ($row in $Additions) {
        $merged[$row.Name] = $row
    }

    $merged.Values | Sort-Object Name |
        Export-Csv -LiteralPath $indexPath -NoTypeInformation -Encoding UTF8

    Write-Host "  Index     : $indexPath  ($($merged.Count) files)"
}

# --------------------------------------------------------------------------
# PASS 2 -- apply a reviewed plan
# --------------------------------------------------------------------------

function Invoke-Plan {
    param(
        [string] $Plan,
        [string] $LibraryRoot,
        [bool]   $UseCopy,
        [string] $Quarantine
    )

    if (-not (Test-Path -LiteralPath $Plan)) {
        throw "Plan not found: $Plan"
    }

    $rows = @(Import-Csv -LiteralPath $Plan)
    if ($rows.Count -eq 0) { throw "Plan is empty: $Plan" }

    # Trust the plan over the -Root parameter. A plan carries its own library root in
    # every destination, so applying one for a different root cannot end up reporting
    # against the default path.
    $keepRow = @($rows | Where-Object { $_.Action -eq 'Keep' })[0]
    if ($null -ne $keepRow) {
        $planRoot = Split-Path -Parent $keepRow.DestinationPath
        if ($planRoot -ne $LibraryRoot) {
            Write-Warning "Plan targets $planRoot, not $LibraryRoot. Using the plan's root."
            $LibraryRoot = $planRoot
            $Quarantine = Join-Path $planRoot (Split-Path -Leaf $Quarantine)
        }
    }

    $verb = if ($UseCopy) { 'Copy' } else { 'Move' }
    Write-Section "$verb pass -- $($rows.Count) planned actions"

    $manifestPath = Join-Path (Split-Path -Parent $Plan) 'manifest.csv'
    $manifest = [System.Collections.Generic.List[object]]::new()
    $indexAdds = [System.Collections.Generic.List[object]]::new()

    $done = 0
    $failed = 0
    $skipped = 0

    foreach ($row in $rows) {
        $done++
        if ($done % 100 -eq 0 -or $done -eq $rows.Count) {
            Write-Progress -Activity "$verb pass" -Status "$done / $($rows.Count)" `
                -PercentComplete (($done / $rows.Count) * 100)
        }

        if ($row.Action -eq 'Skip') { $skipped++; continue }

        if (-not (Test-Path -LiteralPath $row.SourcePath)) {
            Write-Warning "Source vanished, skipping: $($row.SourcePath)"
            $failed++
            continue
        }

        $destDir = Split-Path -Parent $row.DestinationPath
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }

        # The plan guarantees unique destinations, but the disk may have changed
        # since the scan. Never clobber.
        $finalDest = $row.DestinationPath
        if (Test-Path -LiteralPath $finalDest) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($finalDest)
            $ext = [System.IO.Path]::GetExtension($finalDest)
            $n = 1
            while (Test-Path -LiteralPath $finalDest) {
                $finalDest = Join-Path $destDir ("{0}_dup{1}{2}" -f $base, $n, $ext)
                $n++
            }
            Write-Warning "Destination existed, using: $(Split-Path -Leaf $finalDest)"
        }

        try {
            if ($UseCopy) {
                Copy-Item -LiteralPath $row.SourcePath -Destination $finalDest -Force:$false
            } else {
                Move-Item -LiteralPath $row.SourcePath -Destination $finalDest -Force:$false
            }

            $manifest.Add([PSCustomObject]@{
                Action          = $row.Action
                Operation       = $verb
                OriginalPath    = $row.SourcePath
                CurrentPath     = $finalDest
            })

            if ($row.Action -eq 'Keep') {
                $indexAdds.Add([PSCustomObject]@{
                    Name        = Split-Path -Leaf $finalDest
                    CameraName  = $row.OriginalName
                    CaptureDate = $row.CaptureDate
                })
            }
        }
        catch {
            Write-Warning "Failed on $($row.SourcePath): $($_.Exception.Message)"
            $failed++
        }
    }

    Write-Progress -Activity "$verb pass" -Completed

    $manifest | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding UTF8
    Update-LibraryIndex -RunDir (Split-Path -Parent $Plan) -Additions $indexAdds

    Write-Host ''
    Write-Host "  Completed : $($manifest.Count)" -ForegroundColor Green
    Write-Host "  Skipped   : $skipped"
    if ($failed -gt 0) {
        Write-Host "  Failed    : $failed" -ForegroundColor Yellow
    }
    Write-Host "  Manifest  : $manifestPath"
    Write-Host ''
    Write-Host "  To reverse: .\Undo-Migration.ps1 -ManifestPath `"$manifestPath`"" -ForegroundColor Cyan

    if (-not $UseCopy) {
        # Directories that are now empty are noise; report but do not delete.
        $emptyDirs = @(Get-ChildItem -LiteralPath $LibraryRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -notlike "$Quarantine*" -and
                @(Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue).Count -eq 0
            })
        if ($emptyDirs.Count -gt 0) {
            Write-Host ''
            Write-Host "  $($emptyDirs.Count) folders are now empty. Review, then remove with:" -ForegroundColor DarkGray
            Write-Host "    Get-ChildItem `"$LibraryRoot`" -Directory -Recurse | Where-Object { @(Get-ChildItem `$_.FullName -Recurse -Force).Count -eq 0 } | Remove-Item -Recurse" -ForegroundColor DarkGray
        }
    }
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $Root)) {
    throw "Root not found: $Root"
}
$Root = (Resolve-Path -LiteralPath $Root).Path
$quarantinePath = Join-Path $Root $QuarantineName

if ($Execute) {
    if ([string]::IsNullOrWhiteSpace($PlanPath)) {
        throw "-Execute requires -PlanPath. Run a dry pass first, review the plan, then apply it."
    }
    Invoke-Plan -Plan $PlanPath -LibraryRoot $Root -UseCopy:$CopyInstead.IsPresent -Quarantine $quarantinePath
    return
}

# ---------- PASS 1: scan ----------

if ([string]::IsNullOrWhiteSpace($ReportRoot)) {
    $ReportRoot = Join-Path $PSScriptRoot 'reports'
}
$runDir = Join-Path $ReportRoot ("run-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

Write-Section 'Scanning'
Write-Host "  Root   : $Root"
Write-Host "  Report : $runDir"

$allFiles = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike "$quarantinePath*" })

$media = [System.Collections.Generic.List[object]]::new()
$sidecars = [System.Collections.Generic.List[object]]::new()
$ignored = [System.Collections.Generic.List[object]]::new()

foreach ($f in $allFiles) {
    $ext = $f.Extension.ToLowerInvariant()
    if ($MediaExtensions -contains $ext) { $media.Add($f) }
    elseif ($SidecarExtensions -contains $ext) { $sidecars.Add($f) }
    else { $ignored.Add($f) }
}

Write-Host "  Media    : $($media.Count)"
Write-Host "  Sidecars : $($sidecars.Count)  (renamed alongside their photo, never deduplicated)"
Write-Host "  Ignored  : $($ignored.Count)   (left where they are)"

if ($ignored.Count -gt 0) {
    $ignored | Select-Object FullName, Extension, Length |
        Export-Csv -LiteralPath (Join-Path $runDir 'ignored-files.csv') -NoTypeInformation -Encoding UTF8
}

if ($media.Count -eq 0) { throw "No media files found under $Root" }

# ---------- dates + hashes ----------

Write-Section 'Reading dates and hashing'

$shell = New-Object -ComObject Shell.Application
$shellFolders = @{}   # directory path -> shell namespace, built once per folder

$entries = [System.Collections.Generic.List[object]]::new()
$processed = 0
$work = @($media) + @($sidecars)

foreach ($f in $work) {
    $processed++
    if ($processed % 50 -eq 0 -or $processed -eq $work.Count) {
        Write-Progress -Activity 'Reading metadata' -Status "$processed / $($work.Count)  $($f.Name)" `
            -PercentComplete (($processed / $work.Count) * 100)
    }

    $dir = $f.DirectoryName
    if (-not $shellFolders.ContainsKey($dir)) {
        $shellFolders[$dir] = $shell.NameSpace($dir)
    }

    $isSidecar = $SidecarExtensions -contains $f.Extension.ToLowerInvariant()
    $resolved = Resolve-CaptureDate -File $f -ShellFolder $shellFolders[$dir]

    # Sidecars are never hashed: identical bytes across unrelated photos are normal.
    $hash = $null
    if (-not $isSidecar) {
        try {
            $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        }
        catch {
            Write-Warning "Could not hash $($f.FullName): $($_.Exception.Message)"
        }
    }

    $relative = $f.FullName.Substring($Root.Length).TrimStart('\')

    $entries.Add([PSCustomObject]@{
        FullName    = $f.FullName
        Name        = $f.Name
        BaseName    = $f.BaseName
        Extension   = $f.Extension.ToLowerInvariant()
        Directory   = $dir
        Relative    = $relative
        Depth       = ($relative -split '\\').Count
        Length      = $f.Length
        Hash        = $hash
        IsSidecar   = $isSidecar
        Date        = $resolved.Date
        DateSource  = $resolved.Source
        # Live Photo / sidecar sets share a folder and a base name.
        PairKey     = ($dir + '|' + $f.BaseName).ToLowerInvariant()
        # Already migrated: sitting in the root under an output-format name.
        IsSettled   = ($Incremental -and $dir -eq $Root -and $f.BaseName -match $SettledNamePattern)
    })
}
Write-Progress -Activity 'Reading metadata' -Completed

$sourceBreakdown = $entries | Group-Object DateSource | Sort-Object Count -Descending
Write-Host ''
Write-Host '  Date sources:'
foreach ($g in $sourceBreakdown) {
    $flag = if ($g.Name -in @('CreationTime', 'Unreliable')) { '  <- check these by hand' } else { '' }
    Write-Host ("    {0,-15} {1,5}{2}" -f $g.Name, $g.Count, $flag)
}

# ---------- duplicate detection ----------

Write-Section 'Duplicate detection'

$duplicateOf = @{}   # FullName -> FullName of the copy being kept
$dupReport = [System.Collections.Generic.List[object]]::new()

$hashGroups = $entries | Where-Object { -not $_.IsSidecar -and $null -ne $_.Hash } |
    Group-Object Hash | Where-Object { $_.Count -gt 1 }

foreach ($group in $hashGroups) {
    $ranked = @($group.Group | Sort-Object { Get-KeeperRank $_ })
    $keeper = $ranked[0]

    foreach ($dup in $ranked[1..($ranked.Count - 1)]) {
        $duplicateOf[$dup.FullName] = $keeper.FullName
        $dupReport.Add([PSCustomObject]@{
            DuplicatePath = $dup.Relative
            KeptPath      = $keeper.Relative
            SizeMB        = [math]::Round($dup.Length / 1MB, 2)
            SHA256        = $group.Name
        })
    }
}

# Measure-Object over an empty collection has no Sum property under StrictMode.
$reclaimed = 0
if ($dupReport.Count -gt 0) {
    $measured = $dupReport | Measure-Object SizeMB -Sum
    if ($null -ne $measured.Sum) { $reclaimed = $measured.Sum }
}
Write-Host "  Byte-identical duplicates : $($dupReport.Count)  ($([math]::Round($reclaimed/1024,2)) GB)"

# duplicates.csv is written after the plan is built, so it can also record the
# name each duplicate ends up under in quarantine and where its kept twin lands.

# The case the user specifically worried about: same filename, different photo.
# These are NOT duplicates and all copies are kept.
$nameCollisions = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($entries | Where-Object { -not $_.IsSidecar } | Group-Object Name | Where-Object { $_.Count -gt 1 })) {
    $distinct = @($group.Group | Select-Object -ExpandProperty Hash -Unique)
    if ($distinct.Count -le 1) { continue }

    foreach ($e in $group.Group) {
        $nameCollisions.Add([PSCustomObject]@{
            SharedFilename = $group.Name
            Path           = $e.Relative
            SHA256Short    = if ($e.Hash) { $e.Hash.Substring(0, 12) } else { '' }
            SizeMB         = [math]::Round($e.Length / 1MB, 2)
        })
    }
}

$collisionNames = @($nameCollisions | Select-Object -ExpandProperty SharedFilename -Unique).Count
Write-Host "  Shared names, different photos : $collisionNames names / $($nameCollisions.Count) files  -- all kept"
if ($nameCollisions.Count -gt 0) {
    $nameCollisions | Sort-Object SharedFilename, Path |
        Export-Csv -LiteralPath (Join-Path $runDir 'same-name-different-photo.csv') -NoTypeInformation -Encoding UTF8
}

# ---------- naming ----------

Write-Section 'Building the rename plan'

$allKeepers = @($entries | Where-Object { -not $duplicateOf.ContainsKey($_.FullName) })

# Settled files are left untouched; only fresh arrivals get named.
$settled = @($allKeepers | Where-Object { $_.IsSettled })
$keepers = @($allKeepers | Where-Object { -not $_.IsSettled })

# Group Live Photo / sidecar sets so they share one sequence number, and take
# the date from the member with the most trustworthy source.
if ($NoPairGrouping) {
    $sets = $keepers | ForEach-Object {
        [PSCustomObject]@{ Members = @($_); Date = $_.Date; Anchor = $_ }
    }
} else {
    $sets = foreach ($g in ($keepers | Group-Object PairKey)) {
        $anchor = @($g.Group | Sort-Object { Get-KeeperRank $_ })[0]
        [PSCustomObject]@{ Members = @($g.Group); Date = $anchor.Date; Anchor = $anchor }
    }
}
$sets = @($sets)

# Sequence numbers run in chronological order within each calendar day, so
# -1, -2, -3 reflect the order the shots were actually taken.
$sets = @($sets | Sort-Object Date, { $_.Anchor.FullName })

$counters = @{}
$claimed = [System.Collections.Generic.HashSet[string]]::new()
$plan = [System.Collections.Generic.List[object]]::new()

# Reserve every settled name and resume each day's numbering from its current high
# water mark, so a new photo from an existing day appends instead of colliding.
foreach ($s in $settled) {
    [void] $claimed.Add($s.Name.ToLowerInvariant())

    if ($s.BaseName -match '^(?<day>\d{8})-(?<n>\d{3})(-.+)?$') {
        $day = $Matches['day']
        $n = [int] $Matches['n']
        if (-not $counters.ContainsKey($day) -or $counters[$day] -lt $n) {
            $counters[$day] = $n
        }
    }

    $plan.Add([PSCustomObject]@{
        Action          = 'Skip'
        SourcePath      = $s.FullName
        DestinationPath = $s.FullName
        NewName         = $s.Name
        OriginalName    = $s.Name
        OriginalFolder  = ''
        CaptureDate     = $s.Date.ToString('yyyy-MM-dd HH:mm:ss')
        DateSource      = $s.DateSource
        SizeMB          = [math]::Round($s.Length / 1MB, 2)
        SHA256          = $s.Hash
    })
}

foreach ($set in $sets) {
    # Year-first so plain filename sort is chronological, and the sequence is padded
    # to three digits so within a day -2 does not sort after -10. The busiest day in
    # this library holds 316 files.
    $day = $set.Date.ToString('yyyyMMdd')
    if (-not $counters.ContainsKey($day)) { $counters[$day] = 0 }
    $counters[$day]++
    $seq = '{0:D3}' -f $counters[$day]

    # Primary media first so a Live Photo's .HEIC and .MOV keep the same number.
    foreach ($member in @($set.Members | Sort-Object IsSidecar, Extension)) {
        $desired = "{0}-{1}{2}" -f $day, $seq, $member.Extension
        $finalName = New-UniqueDestination -Directory $Root -DesiredName $desired -Claimed $claimed

        $plan.Add([PSCustomObject]@{
            Action          = 'Keep'
            SourcePath      = $member.FullName
            DestinationPath = (Join-Path $Root $finalName)
            NewName         = $finalName
            OriginalName    = $member.Name
            OriginalFolder  = (Split-Path -Parent $member.Relative)
            CaptureDate     = $member.Date.ToString('yyyy-MM-dd HH:mm:ss')
            DateSource      = $member.DateSource
            SizeMB          = [math]::Round($member.Length / 1MB, 2)
            SHA256          = $member.Hash
        })
    }
}

# Duplicates keep their original names inside quarantine so they stay
# recognisable if the user wants to inspect before deleting.
$quarantineClaimed = [System.Collections.Generic.HashSet[string]]::new()
foreach ($e in ($entries | Where-Object { $duplicateOf.ContainsKey($_.FullName) })) {
    $finalName = New-UniqueDestination -Directory $quarantinePath -DesiredName $e.Name -Claimed $quarantineClaimed

    $plan.Add([PSCustomObject]@{
        Action          = 'Quarantine'
        SourcePath      = $e.FullName
        DestinationPath = (Join-Path $quarantinePath $finalName)
        NewName         = $finalName
        OriginalName    = $e.Name
        OriginalFolder  = (Split-Path -Parent $e.Relative)
        CaptureDate     = $e.Date.ToString('yyyy-MM-dd HH:mm:ss')
        DateSource      = $e.DateSource
        SizeMB          = [math]::Round($e.Length / 1MB, 2)
        SHA256          = $e.Hash
    })
}

$planPath = Join-Path $runDir 'plan.csv'
$plan | Export-Csv -LiteralPath $planPath -NoTypeInformation -Encoding UTF8

# Enrich the duplicate report with post-migration names, so a manual review can
# be done against the quarantine folder without cross-referencing plan.csv.
if ($dupReport.Count -gt 0) {
    $quarantineNames = @{}
    $keptNames = @{}
    foreach ($row in $plan) {
        if ($row.Action -eq 'Quarantine') { $quarantineNames[$row.SourcePath] = $row.NewName }
        else { $keptNames[$row.SourcePath] = $row.NewName }
    }

    $dupReport | ForEach-Object {
        $dupFull = Join-Path $Root $_.DuplicatePath
        $keptFull = Join-Path $Root $_.KeptPath
        [PSCustomObject]@{
            QuarantinedAs = if ($quarantineNames.ContainsKey($dupFull)) { $quarantineNames[$dupFull] } else { '' }
            KeptAs        = if ($keptNames.ContainsKey($keptFull)) { $keptNames[$keptFull] } else { '' }
            SizeMB        = $_.SizeMB
            DuplicatePath = $_.DuplicatePath
            KeptPath      = $_.KeptPath
            SHA256        = $_.SHA256
        }
    } | Sort-Object { [double] $_.SizeMB } -Descending |
        Export-Csv -LiteralPath (Join-Path $runDir 'duplicates.csv') -NoTypeInformation -Encoding UTF8
}

# ---------- summary ----------

$keepCount = @($plan | Where-Object { $_.Action -eq 'Keep' }).Count
$quarCount = @($plan | Where-Object { $_.Action -eq 'Quarantine' }).Count
$skipCount = @($plan | Where-Object { $_.Action -eq 'Skip' }).Count
$lowConfidence = @($plan | Where-Object { $_.DateSource -in @('CreationTime', 'Unreliable') }).Count

Write-Section 'Dry run complete -- nothing has been changed'
if ($Incremental) {
    Write-Host "  Already migrated, untouched : $skipCount" -ForegroundColor DarkGray
}
Write-Host "  Files to flatten and rename : $keepCount"
Write-Host "  Duplicates to quarantine    : $quarCount"
Write-Host "  Distinct days               : $($counters.Keys.Count)"
if ($lowConfidence -gt 0) {
    Write-Host "  Low-confidence dates        : $lowConfidence  (see DateSource in plan.csv)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Sample of planned renames:' -ForegroundColor DarkGray
$plan | Where-Object { $_.Action -eq 'Keep' } | Select-Object -First 8 |
    Format-Table @{ n = 'From'; e = { "{0}\{1}" -f $_.OriginalFolder, $_.OriginalName } },
                 @{ n = '->'; e = { $_.NewName } },
                 DateSource -AutoSize

Write-Host "  Plan     : $planPath"
Write-Host "  Reports  : $runDir"
Write-Host ''
Write-Host '  Review the plan, then apply it with:' -ForegroundColor Cyan
Write-Host "    .\Migrate-Photos.ps1 -Execute -PlanPath `"$planPath`"" -ForegroundColor Cyan
