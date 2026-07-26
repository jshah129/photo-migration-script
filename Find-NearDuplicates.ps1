<#
.SYNOPSIS
  Finds photos that are the same shot stored twice in different formats, which
  byte-level deduplication cannot detect.

.DESCRIPTION
  When an iPhone import converts HEIC to JPEG, you end up with two files that are
  the same photograph but share not a single byte. SHA-256 correctly refuses to call
  them duplicates, so Migrate-Photos.ps1 keeps both. This script finds them.

  A pair is reported only when ALL of these hold:

    * the camera filenames share a stem  -- IMG_7533.HEIC and IMG_7533.JPG
    * the capture instants match         -- so two devices reusing IMG_7533 don't collide
    * both files are stills              -- HEIC + MOV is a Live Photo, not a duplicate
    * the formats differ                 -- otherwise it is a byte-dedup matter

  Matching on the stem alone is unsafe because iPhones recycle IMG_#### numbers, and
  matching on capture time alone is far too loose: Windows exposes "Date taken" only
  to the minute, so a burst of shots shares one timestamp. Together they are precise.

  Apple's edited renditions (IMG_E7533) are tracked as a separate stem from the
  original (IMG_7533), because an edit is a genuinely different image.

  Nothing is moved or deleted. Choosing a format is a judgement call:

    HEIC  - the original, about half the size, better quality, poor compatibility
    JPEG  - converted, larger, slightly lossy, opens anywhere

.PARAMETER HistoryPlanPath
  Files already migrated no longer carry their camera filename -- the current plan
  only knows them as 20231008-001.jpg. Point this at the plan.csv from the run that
  originally renamed them to recover the mapping. Without it, only pairs among newly
  arriving files can be found.

.EXAMPLE
  .\Find-NearDuplicates.ps1 -PlanPath .\reports\run-B\plan.csv `
                            -HistoryPlanPath .\reports\run-A\plan.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $PlanPath,

    # Accepts several plans. Each incremental import adds a generation of settled
    # files, so pass every prior run's plan to resolve all of them.
    [string[]] $HistoryPlanPath,

    # If files were renamed after a history plan was written, supply the rename log
    # (a CSV with Old and New columns) so the chain current -> old -> camera resolves.
    [string[]] $RenameMapPath,

    # Where to write the report. Defaults to the plan's own folder.
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$StillExtensions = @('.heic', '.heif', '.jpg', '.jpeg', '.png', '.webp', '.tif', '.tiff', '.dng')

if (-not (Test-Path -LiteralPath $PlanPath)) { throw "Plan not found: $PlanPath" }
$rows = @(Import-Csv -LiteralPath $PlanPath)
if ($rows.Count -eq 0) { throw "Plan is empty: $PlanPath" }

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $PlanPath) 'possible-duplicates.csv'
}

# Current name -> the name it had when the history plan was written.
$rename = @{}
foreach ($path in @($RenameMapPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Rename map not found: $path" }
    foreach ($m in (Import-Csv -LiteralPath $path)) {
        if (-not $rename.ContainsKey($m.New)) { $rename[$m.New] = $m.Old }
    }
}
if ($rename.Count -gt 0) {
    Write-Host "  Loaded $($rename.Count) rename mappings." -ForegroundColor DarkGray
}

# Recover camera filenames for files migrated by earlier runs. Later plans are
# merged first so the most recent generation wins any name reused across runs.
$history = @{}
foreach ($path in @($HistoryPlanPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    if (-not (Test-Path -LiteralPath $path)) { throw "History plan not found: $path" }
    foreach ($h in (Import-Csv -LiteralPath $path)) {
        if ($h.Action -eq 'Keep' -and -not $history.ContainsKey($h.NewName)) {
            $history[$h.NewName] = $h.OriginalName
        }
    }
}
if ($history.Count -gt 0) {
    Write-Host "  Recovered $($history.Count) camera filenames from $(@($HistoryPlanPath).Count) history plan(s)." -ForegroundColor DarkGray
}

<#
  "IMG_7533.HEIC" -> "7533", "IMG_E7533.HEIC" -> "E7533". Returns $null when the
  name carries no camera number, in which case the file cannot be matched this way.
#>
function Get-CameraStem {
    param([string] $Name)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $m = [regex]::Match($base, '^(?:IMG|DSC|DSCN|PXL|MVIMG|VID)[_-]?(?<e>E?)(?<n>\d{3,})')
    if (-not $m.Success) { return $null }
    return $m.Groups['e'].Value.ToUpperInvariant() + $m.Groups['n'].Value
}

$groups = @{}
foreach ($row in $rows) {
    # Resolve the camera filename: settled rows need the history map.
    $cameraName = $row.OriginalName
    if ($row.Action -eq 'Skip') {
        $historic = $row.OriginalName
        if ($rename.ContainsKey($historic)) { $historic = $rename[$historic] }
        if ($history.ContainsKey($historic)) { $cameraName = $history[$historic] }
    }

    $stem = Get-CameraStem $cameraName
    if ($null -eq $stem) { continue }

    $ext = ([System.IO.Path]::GetExtension($row.NewName)).ToLowerInvariant()
    if ($StillExtensions -notcontains $ext) { continue }   # Live Photo MOVs, sidecars

    $key = '{0}|{1}' -f $stem, ([datetime] $row.CaptureDate).ToString('yyyyMMddHHmm')
    if (-not $groups.ContainsKey($key)) {
        $groups[$key] = [System.Collections.Generic.List[object]]::new()
    }
    $groups[$key].Add([PSCustomObject]@{
        Row = $row; Stem = $stem; Ext = $ext; CameraName = $cameraName
    })
}

$report = [System.Collections.Generic.List[object]]::new()

foreach ($key in $groups.Keys) {
    $g = @($groups[$key])
    if ($g.Count -lt 2) { continue }
    # Same format twice is a byte-dedup question, not a format-conversion pair.
    if (@($g | Select-Object -ExpandProperty Ext -Unique).Count -lt 2) { continue }

    $existing = @($g | Where-Object { $_.Row.Action -eq 'Skip' })
    $arriving = @($g | Where-Object { $_.Row.Action -ne 'Skip' })

    $relationship =
        if ($existing.Count -gt 0 -and $arriving.Count -gt 0) { 'NewVsExisting' }
        elseif ($existing.Count -gt 0) { 'WithinExisting' }
        else { 'WithinImport' }

    foreach ($item in ($g | Sort-Object { [double] $_.Row.SizeMB } -Descending)) {
        $report.Add([PSCustomObject]@{
            CameraStem   = $item.Stem
            CapturedAt   = ([datetime] $item.Row.CaptureDate).ToString('yyyy-MM-dd HH:mm')
            Relationship = $relationship
            Status       = if ($item.Row.Action -eq 'Skip') { 'Existing' } else { 'Arriving' }
            Format       = $item.Ext.TrimStart('.').ToUpperInvariant()
            SizeMB       = $item.Row.SizeMB
            Name         = $item.Row.NewName
            CameraName   = $item.CameraName
            FoundIn      = if ($item.Row.Action -eq 'Skip') { 'already in library' } else { $item.Row.OriginalFolder }
        })
    }
}

$sorted = @($report | Sort-Object CapturedAt, CameraStem, @{ Expression = { [double] $_.SizeMB }; Descending = $true })
$sorted | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8

$pairCount = @($sorted | Group-Object { $_.CameraStem + $_.CapturedAt }).Count

Write-Host ''
Write-Host '=== Same photo, different format ===' -ForegroundColor Cyan
Write-Host "  Matched groups : $pairCount"
Write-Host "  Files involved : $($sorted.Count)"
Write-Host ''
foreach ($g in ($sorted | Group-Object Relationship | Sort-Object Count -Descending)) {
    $label = switch ($g.Name) {
        'NewVsExisting'  { 'arriving file matches one already in the library' }
        'WithinImport'   { 'two arriving files match each other' }
        'WithinExisting' { 'two library files match each other' }
        default          { $g.Name }
    }
    Write-Host ("    {0,-16} {1,5} files  {2}" -f $g.Name, $g.Count, $label)
}

Write-Host ''
Write-Host '  Formats:'
foreach ($f in ($sorted | Group-Object Format | Sort-Object Count -Descending)) {
    Write-Host ("    {0,-6} {1,5}" -f $f.Name, $f.Count)
}

# Space freed by keeping the largest copy in each group is a poor proxy; report the
# smaller-copy total instead, which is what dropping the redundant rendition saves.
$reclaim = 0
foreach ($g in ($sorted | Group-Object { $_.CameraStem + $_.CapturedAt })) {
    $sizes = @($g.Group | ForEach-Object { [double] $_.SizeMB } | Sort-Object -Descending)
    if ($sizes.Count -gt 1) { $reclaim += ($sizes | Select-Object -Skip 1 | Measure-Object -Sum).Sum }
}
Write-Host ''
Write-Host ("  Keeping one copy per group would free {0} GB" -f [math]::Round($reclaim / 1024, 2))
Write-Host ''
Write-Host "  Report: $OutputPath"
Write-Host '  Nothing was moved or deleted.' -ForegroundColor DarkGray
Write-Host ''
