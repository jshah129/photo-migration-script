<#
.SYNOPSIS
  Reverses a Migrate-Photos.ps1 run using the manifest it wrote.

.DESCRIPTION
  Walks the manifest in reverse and returns every file to the exact path it came
  from, recreating the original folders as needed. Files that were copied rather
  than moved are deleted from the destination instead.

  Nothing is overwritten: if a file already sits at the original path, that row
  is reported and skipped.

.EXAMPLE
  .\Undo-Migration.ps1 -ManifestPath .\reports\run-20260726-101500\manifest.csv -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string] $ManifestPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest not found: $ManifestPath"
}

$rows = @(Import-Csv -LiteralPath $ManifestPath)
if ($rows.Count -eq 0) { throw "Manifest is empty: $ManifestPath" }

Write-Host ''
Write-Host "=== Undo -- $($rows.Count) entries ===" -ForegroundColor Cyan

$restored = 0
$skipped = 0
$failed = 0
$index = 0

# Reverse order so nested restores resolve cleanly.
[array]::Reverse($rows)

foreach ($row in $rows) {
    $index++
    if ($index % 100 -eq 0 -or $index -eq $rows.Count) {
        Write-Progress -Activity 'Undoing' -Status "$index / $($rows.Count)" `
            -PercentComplete (($index / $rows.Count) * 100)
    }

    if (-not (Test-Path -LiteralPath $row.CurrentPath)) {
        Write-Warning "Not at expected location, skipping: $($row.CurrentPath)"
        $skipped++
        continue
    }

    try {
        if ($row.Operation -eq 'Copy') {
            # The original was never moved; just remove the copy.
            if ($PSCmdlet.ShouldProcess($row.CurrentPath, 'Remove copy')) {
                Remove-Item -LiteralPath $row.CurrentPath -Force
                $restored++
            }
            continue
        }

        if (Test-Path -LiteralPath $row.OriginalPath) {
            Write-Warning "Original path occupied, skipping: $($row.OriginalPath)"
            $skipped++
            continue
        }

        $originalDir = Split-Path -Parent $row.OriginalPath
        if (-not (Test-Path -LiteralPath $originalDir)) {
            New-Item -ItemType Directory -Force -Path $originalDir | Out-Null
        }

        if ($PSCmdlet.ShouldProcess($row.CurrentPath, "Restore to $($row.OriginalPath)")) {
            Move-Item -LiteralPath $row.CurrentPath -Destination $row.OriginalPath -Force:$false
            $restored++
        }
    }
    catch {
        Write-Warning "Failed on $($row.CurrentPath): $($_.Exception.Message)"
        $failed++
    }
}

Write-Progress -Activity 'Undoing' -Completed

Write-Host ''
Write-Host "  Restored : $restored" -ForegroundColor Green
Write-Host "  Skipped  : $skipped"
if ($failed -gt 0) {
    Write-Host "  Failed   : $failed" -ForegroundColor Yellow
}
Write-Host ''
