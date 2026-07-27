<#
.SYNOPSIS
One-time setup for the nightmix toolkit: put bin/ on the user PATH.

.DESCRIPTION
Adds this repository's bin/ directory to the *user* PATH (no admin rights),
idempotently: running twice does not duplicate the entry, and if the repo has
been moved the stale entry is replaced rather than left behind. Then checks the
PowerShell execution policy and verifies ffmpeg/ffprobe (>= 6.0, for
dialoguenhance).

Run once after cloning; run again after moving the repo.

.PARAMETER Uninstall
Remove nightmix's bin/ entry from the user PATH (and any scoop shims) instead of
adding it.

.PARAMETER Scoop
If scoop is installed, register 'nmprobe'/'nmconvert' shims in ~\scoop\shims
instead of editing PATH. Mutually exclusive with the PATH edit — never both.

.PARAMETER DryRun
Print what would change without touching PATH, the registry, or scoop.

.EXAMPLE
.\install.ps1

.EXAMPLE
.\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Scoop,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------------------
# Pure helpers (no side effects — unit-testable)
# ---------------------------------------------------------------------------

function Get-NormalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim().Trim('"')
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { }
    return $p.TrimEnd('\')
}

# Is this PATH entry a nightmix bin/ directory (ours, or a stale one)?
function Test-NightmixBinEntry {
    param([string]$Entry, [string]$BinPath)

    $n = Get-NormalPath $Entry
    if (-not $n) { return $false }

    # Exact match (dedupe / idempotency).
    if ($n -ieq $BinPath) { return $true }

    # Only ever consider directories literally named 'bin'.
    if ((Split-Path $n -Leaf) -ine 'bin') { return $false }

    # A live nightmix install at a different location: it still holds our script.
    # Use [IO.Path]::Combine, not Join-Path — the latter throws on a PATH entry
    # whose drive is currently absent (an unplugged drive, or a moved repo).
    if (Test-Path -LiteralPath ([System.IO.Path]::Combine($n, 'nightmix-probe.ps1'))) { return $true }

    # A stale entry from a moved/removed repo: the directory is gone and its
    # parent folder name looks like a nightmix checkout. Kept deliberately
    # narrow so unrelated dead '...\bin' entries are never touched.
    if (-not (Test-Path -LiteralPath $n)) {
        $parent = Split-Path $n -Parent
        if ($parent) {
            $parentLeaf = Split-Path $parent -Leaf
            if ($parentLeaf -match '(?i)nightmix') { return $true }
        }
    }

    return $false
}

# Given the current PATH entries, return the new set: all existing nightmix bin
# entries stripped, then (unless -Remove) our BinPath appended once.
function Get-NightmixPath {
    param(
        [string[]]$Entries,
        [Parameter(Mandatory)][string]$BinPath,
        [switch]$Remove
    )
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Entries) {
        if ([string]::IsNullOrWhiteSpace($e)) { continue }
        if (Test-NightmixBinEntry -Entry $e -BinPath $BinPath) { continue }
        $kept.Add($e)
    }
    if (-not $Remove) { $kept.Add($BinPath) }
    return $kept.ToArray()
}

# Parse the major version from an `ffmpeg -version` first line. Returns an int,
# or $null when the build is date/git-tagged (no dotted release version).
function Get-FFmpegMajorVersion {
    param([string]$VersionLine)
    if (-not $VersionLine) { return $null }
    # Match a 1-2 digit dotted major (6.x, 7.1) but not a 2024-... date build.
    if ($VersionLine -match 'version\s+n?(\d{1,2})\.\d') { return [int]$Matches[1] }
    return $null
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Step { param([string]$Text) Write-Host $Text }
function Write-Ok   { param([string]$Text) Write-Host "  $Text" }
function Write-Warn2 { param([string]$Text) Write-Host "  ! $Text" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$repoRoot = $PSScriptRoot
$binPath  = Get-NormalPath (Join-Path $repoRoot 'bin')
$mode     = if ($Uninstall) { 'Uninstalling' } else { 'Installing' }
$dryTag   = if ($DryRun) { ' (dry run - nothing will change)' } else { '' }

Write-Step "nightmix — $mode$dryTag"

if (-not (Test-Path -LiteralPath $binPath)) {
    Write-Warn2 "bin/ not found at: $binPath"
    Write-Warn2 "Run this script from the repository root."
}

$scoopAvailable = [bool](Get-Command scoop -ErrorAction SilentlyContinue)

if ($Scoop -and -not $scoopAvailable) {
    Write-Warn2 "-Scoop was requested but scoop is not installed. Falling back to PATH."
    $Scoop = $false
}

# --- 1. Register shims (scoop) OR edit PATH ---

if ($Scoop) {
    Write-Step "1. scoop shims (instead of PATH)"
    $shims = @(
        @{ Name = 'nmprobe';   Script = 'nightmix-probe.ps1' }
        @{ Name = 'nmconvert'; Script = 'nightmix-convert.ps1' }
    )
    foreach ($shim in $shims) {
        $target = Join-Path $binPath $shim.Script
        if ($Uninstall) {
            if ($DryRun) { Write-Ok "would: scoop shim rm $($shim.Name)" }
            else { & scoop shim rm $shim.Name 2>$null; Write-Ok "removed shim $($shim.Name)" }
        } else {
            if (-not (Test-Path -LiteralPath $target)) {
                Write-Warn2 "skipping $($shim.Name): $($shim.Script) does not exist yet"
                continue
            }
            if ($DryRun) { Write-Ok "would: scoop shim add $($shim.Name) `"$target`"" }
            else { & scoop shim add $shim.Name $target | Out-Null; Write-Ok "added shim $($shim.Name) -> $target" }
        }
    }
} else {
    Write-Step "1. User PATH"
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries  = @()
    if ($userPath) { $entries = $userPath -split ';' }

    $existing = @($entries | Where-Object { Test-NightmixBinEntry -Entry $_ -BinPath $binPath })
    $hadExact = @($existing | Where-Object { (Get-NormalPath $_) -ieq $binPath }).Count -gt 0
    $staleCount = $existing.Count - $(if ($hadExact) { 1 } else { 0 })

    $newEntries = Get-NightmixPath -Entries $entries -BinPath $binPath -Remove:$Uninstall
    $newPath    = ($newEntries -join ';')

    if ($Uninstall) {
        if ($existing.Count -eq 0) { Write-Ok "nightmix was not on PATH — nothing to remove." }
        else { Write-Ok "removing $($existing.Count) nightmix entr$(if($existing.Count -eq 1){'y'}else{'ies'}) from PATH." }
    } else {
        if ($hadExact -and $existing.Count -eq 1) { Write-Ok "already on PATH — no change: $binPath" }
        elseif ($staleCount -gt 0) { Write-Ok "replacing $staleCount stale entr$(if($staleCount -eq 1){'y'}else{'ies'}); PATH now points at: $binPath" }
        else { Write-Ok "adding to PATH: $binPath" }
    }

    if ($DryRun) {
        Write-Ok "would set user PATH to:"
        Write-Host ("      " + ($newEntries -join "`n      "))
    } elseif ($existing.Count -gt 0 -or -not $Uninstall) {
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    }

    if ($scoopAvailable -and -not $Uninstall) {
        Write-Ok "(scoop detected: you could instead run '.\install.ps1 -Scoop' to use shims without editing PATH.)"
    }
}

if ($Uninstall) {
    Write-Step "Done$dryTag. Open a new PowerShell window for the change to take effect."
    return
}

# --- 2. Execution policy ---

Write-Step "2. Execution policy"
$effective = Get-ExecutionPolicy
if ($effective -in @('Restricted', 'AllSigned')) {
    Write-Warn2 "current policy is '$effective' — .ps1 scripts are blocked. To allow them, run:"
    Write-Host  "      Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser"
    Write-Ok    "(not changed automatically — that is your call.)"
} else {
    Write-Ok "policy '$effective' allows scripts. OK."
}

# --- 3. ffmpeg / ffprobe ---

Write-Step "3. ffmpeg / ffprobe"
foreach ($tool in @('ffmpeg', 'ffprobe')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Warn2 "$tool not found on PATH. Install it (e.g. 'scoop install ffmpeg')."
    } else {
        Write-Ok "$tool found."
    }
}

$ffmpegVersionLine = $null
if (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    # Capture fully, then take the first line. Piping straight into
    # `Select-Object -First 1` severs the pipe early and leaves $LASTEXITCODE
    # at a spurious non-zero (the forced-termination code).
    $ffmpegVersionOut  = & ffmpeg -version
    $ffmpegVersionLine = @($ffmpegVersionOut)[0]
    if ($ffmpegVersionLine) { Write-Ok $ffmpegVersionLine }
    $major = Get-FFmpegMajorVersion $ffmpegVersionLine
    if ($null -eq $major) {
        Write-Warn2 "could not determine ffmpeg version (git/date build?). Ensure it is 6.0+ for dialoguenhance."
    } elseif ($major -lt 6) {
        Write-Warn2 "ffmpeg $major is below 6.0 — dialoguenhance is unavailable; nightmix-convert.ps1 audio will fail."
    } else {
        Write-Ok "version >= 6.0. OK."
    }
}

# --- 4. Next steps ---

Write-Step "Done$dryTag."
if (-not $Scoop) {
    Write-Host ""
    Write-Host "Open a new PowerShell window (this one won't see the new PATH), then:"
    Write-Host ""
    Write-Host '    cd "E:\Video\Some Clip"'
    Write-Host '    nightmix-probe.ps1 "clip.mkv"'
    Write-Host ""
    Write-Host "Tip: to type 'nightmix-probe' without the .ps1, add .PS1 to your PATHEXT."
}
