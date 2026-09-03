<#
.SYNOPSIS
Mux a ripped DVD's main title (a VIDEO_TS folder) into a single MKV.

.DESCRIPTION
A VIDEO_TS folder holds several titles (menus, trailers, logos, the feature) as
VTS_<NN>_<M>.VOB files. This picks the largest title group as the main title,
excludes the _0.VOB menu/navigation part, and byte-concatenates the remaining
VOBs (MPEG-PS) into one MKV with `-c copy` (no re-encode). Run
nightmix-convert.ps1 on the result afterwards.

DVD subtitles are image-based (VOBSUB) and are kept here but will be skipped by
nightmix-convert.ps1.

.PARAMETER DryRun
Print the title decision and the ffmpeg command without running anything.
.PARAMETER Force
Allow overwriting an existing result file.
.PARAMETER OutputDirectory
Where a bare result filename lands, overriding $DefaultOutputDirectory from
config.ps1 for this run. Ignored when the result carries a path of its own.
.PARAMETER Directory
Positional 0, mandatory. The folder containing VIDEO_TS, or the VIDEO_TS folder itself.
.PARAMETER Result
Positional 1, mandatory. Output .mkv path. A bare filename goes to the default
output directory if one is configured; anything with a path in it is taken
literally.

.EXAMPLE
nightmix-dvdmux.ps1 "D:\rips\SomeDisc" "disc.mkv"
.EXAMPLE
nightmix-dvdmux.ps1 -DryRun "D:\rips\SomeDisc\VIDEO_TS" "disc.mkv"
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [string]$OutputDirectory,
    [Parameter(Mandatory, Position = 0)][string]$Directory,
    [Parameter(Mandatory, Position = 1)][string]$Result
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

# Title-table size format: gibibytes, 2 decimals, invariant (dot) — matches §6.2.
function Format-GiB {
    param([double]$Bytes)
    return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.00} GB', ($Bytes / 1GB)))
}

try {
    Assert-Tool $FFmpegPath

    # --- Resolve the directory and locate VIDEO_TS ---
    $dirAbs = Resolve-InputPath $Directory
    if (-not (Test-Path -LiteralPath $dirAbs -PathType Container)) {
        throw (New-NightmixError "not a directory: $dirAbs" 1)
    }

    if ((Split-Path $dirAbs -Leaf) -ieq 'VIDEO_TS') {
        $vtsDir = $dirAbs
    } elseif (Test-Path -LiteralPath (Join-Path $dirAbs 'VIDEO_TS') -PathType Container) {
        $vtsDir = (Join-Path $dirAbs 'VIDEO_TS')
    } else {
        # No VIDEO_TS subfolder and not named VIDEO_TS — accept a folder that
        # holds the VOBs directly; fail later if there are none.
        $vtsDir = $dirAbs
    }

    # --- Resolve the result path ---
    # A bare result filename may be redirected to a configured directory;
    # -OutputDirectory beats config.ps1, and a result carrying a path beats both.
    $outDir = if ($OutputDirectory) { $OutputDirectory } else { $DefaultOutputDirectory }
    $targetAbs = Resolve-OutputPath -Path $Result -Directory $outDir

    $targetExists = Test-Path -LiteralPath $targetAbs
    $existsNeedsForce = $false
    if ($targetExists -and -not $Force) {
        # A real run refuses to overwrite; a -DryRun still previews the command.
        if (-not $DryRun) {
            throw (New-NightmixError "result already exists: $targetAbs (use -Force to overwrite)." 1)
        }
        $existsNeedsForce = $true
    }

    # --- Enumerate VTS_<NN>_<M>.VOB and group by NN (6.2) ---
    $vobs = @(Get-ChildItem -LiteralPath $vtsDir -File -Filter 'VTS_*.VOB' -ErrorAction SilentlyContinue)
    $groups = @{}
    foreach ($f in $vobs) {
        if ($f.Name -match '^VTS_(\d+)_(\d+)\.VOB$') {
            $nn = [int]$Matches[1]
            $m  = [int]$Matches[2]
            if ($m -eq 0) { continue }   # _0.VOB is menu/navigation, not content
            if (-not $groups.ContainsKey($nn)) { $groups[$nn] = @() }
            $groups[$nn] += [pscustomobject]@{ M = $m; File = $f; Size = $f.Length }
        }
    }

    if ($groups.Count -eq 0) {
        throw (New-NightmixError "no VTS_<NN>_<M>.VOB content files found in: $vtsDir" 1)
    }

    # --- Pick the largest group; order its files by M ---
    # @() is required: with a single group this would be one PSCustomObject
    # whose own 'Count' property (its file count) would shadow the collection
    # count, making the report say "Found 2 titles" for one 2-file title.
    $summaries = @(foreach ($nn in ($groups.Keys | Sort-Object)) {
        $files = @($groups[$nn] | Sort-Object M)
        [pscustomobject]@{
            NN    = $nn
            Files = $files
            Count = $files.Count
            Total = ($files | Measure-Object -Property Size -Sum).Sum
        }
    })
    $selected = $summaries | Sort-Object Total -Descending | Select-Object -First 1

    # --- Report the decision (both dry and real runs) ---
    $report = New-Object System.Collections.Generic.List[string]
    $report.Add("Found $($summaries.Count) title$(if ($summaries.Count -ne 1) { 's' }):")
    foreach ($g in $summaries) {
        $mark = if ($g.NN -eq $selected.NN) { '   <- selected' } else { '' }
        $countText = "$($g.Count) file$(if ($g.Count -ne 1) { 's' })"
        $report.Add(('  VTS_{0:00}  {1,-8} {2,9}{3}' -f $g.NN, $countText, (Format-GiB $g.Total), $mark))
    }
    $report.Add('')
    $report.Add("Source:  $vtsDir")
    # Full path, not just the name: with a default output directory in play the
    # destination is no longer obvious from the command line.
    $report.Add("Target:  $targetAbs")
    Write-Plan -Lines $report.ToArray()

    if ($selected.Total -lt 100MB) {
        Write-Output ''
        Write-Output "Warning: the selected title is only $(Format-GiB $selected.Total) - this looks too small to be a main title, but proceeding."
    }
    if ($existsNeedsForce) {
        Write-Output ''
        Write-Output "Note: result exists; a real run would need -Force to overwrite it."
    }
    Write-Output ''

    # --- Build the concat input and ffmpeg command (6.3) ---
    $concatInput = 'concat:' + (($selected.Files | ForEach-Object { $_.File.FullName }) -join '|')

    $ff = New-Object System.Collections.Generic.List[string]
    # (banner and stream dumps are suppressed by the -loglevel flag Invoke-FFmpeg adds)
    if ($targetExists -and $Force) { $ff.Add('-y') }
    # Large probe window is required: concat: probes only the start, so subtitle
    # streams that first appear later would otherwise be missed.
    $ff.AddRange([string[]]@('-analyzeduration', '200M', '-probesize', '200M'))
    $ff.AddRange([string[]]@('-i', $concatInput))
    $ff.AddRange([string[]]@('-map', '0', '-c', 'copy', '-f', 'matroska'))
    $ff.Add($targetAbs)

    Invoke-FFmpeg -Arguments $ff.ToArray() -DryRun:$DryRun

    if (-not $DryRun) {
        Write-Output ''
        Write-Output "Done. -> $targetAbs"
        Write-Output 'Subtitles in this file are image-based (VOBSUB) and will be skipped by'
        Write-Output 'nightmix-convert.ps1. Run nightmix-probe.ps1 on the result to see the streams.'
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit (Get-NightmixExitCode $_)
}
