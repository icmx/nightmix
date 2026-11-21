<#
.SYNOPSIS
One-time setup for the nightmix toolkit: put bin/ on the user PATH.

.DESCRIPTION
Adds this repository's bin/ directory to the *user* PATH (no admin rights; running
twice does not duplicate it), checks that ffmpeg has the dialoguenhance filter,
and creates config.ps1 from config.example.ps1 if it does not exist yet.

.PARAMETER Uninstall
Remove bin/ from the user PATH instead. config.ps1 is left alone.

.EXAMPLE
.\install.ps1
.EXAMPLE
.\install.ps1 -Uninstall
#>
[CmdletBinding()]
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Get-NormalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim().Trim('"')
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { }
    return $p.TrimEnd('\')
}

$binPath = Get-NormalPath (Join-Path $PSScriptRoot 'bin')

# --- User PATH ---
$entries = @([Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ })
$others  = @($entries | Where-Object { (Get-NormalPath $_) -ine $binPath })
$present = $others.Count -lt $entries.Count

if ($Uninstall) {
    if ($present) {
        [Environment]::SetEnvironmentVariable('Path', ($others -join ';'), 'User')
        Write-Host "Removed from user PATH: $binPath (takes effect in new PowerShell windows)"
    } else {
        Write-Host "Not on user PATH, nothing to remove: $binPath"
    }
    return
}

if ($present) {
    Write-Host "Already on user PATH: $binPath"
} else {
    [Environment]::SetEnvironmentVariable('Path', (($entries + $binPath) -join ';'), 'User')
    Write-Host "Added to user PATH: $binPath (open a new PowerShell window to use it)"
}

# --- ffmpeg: what matters is the dialoguenhance filter (ffmpeg 6.0+) ---
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue) -or
    -not (Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "ffmpeg/ffprobe not found on PATH. Install them, e.g. 'scoop install ffmpeg'." -ForegroundColor Yellow
} elseif (-not (& ffmpeg -hide_banner -filters | Select-String -SimpleMatch 'dialoguenhance')) {
    Write-Host "This ffmpeg has no dialoguenhance filter (needs 6.0+); nightmix-convert.ps1 audio will fail." -ForegroundColor Yellow
} else {
    Write-Host "ffmpeg OK (dialoguenhance available)."
}

# --- Local configuration: created once, never overwritten ---
$configPath = Join-Path $PSScriptRoot 'config.ps1'
if (Test-Path -LiteralPath $configPath) {
    Write-Host "config.ps1 already exists, left untouched."
} else {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config.example.ps1') -Destination $configPath
    Write-Host "Created config.ps1 from config.example.ps1 (not tracked by git)."
}
