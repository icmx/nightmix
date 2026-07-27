# lib/common.ps1
#
# Shared configuration constants and helper functions for the nightmix toolkit.
# Dot-sourced by the bin/ entry points; never run directly.
#
# See docs/spec-lean.md sections 4, 7.4, 8.4 and 9.

# Cyrillic track titles from ffprobe and Cyrillic output filenames need UTF-8.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------------------
# 4.1 Configuration constants
# ---------------------------------------------------------------------------

# Tool paths
$FFmpegPath  = 'ffmpeg'      # resolved via PATH; override with a full path
$FFprobePath = 'ffprobe'

# Video profiles - tuned for decode cost, not archival quality.
$VideoProfiles = @{
    standard = @{ Size = '1920x1080'; Crf = 22; Level = '4.0'; MaxRate = '8M'; BufSize = '16M' }
    light    = @{ Size = '1280x720';  Crf = 23; Level = '3.1'; MaxRate = '4M'; BufSize = '8M'  }
}
$DefaultVideoProfile = 'standard'

$VideoCodec        = 'libx264'
$VideoPreset       = 'veryfast'
$VideoTune         = 'fastdecode'
$H264Profile       = 'high'
$PixelFormat       = 'yuv420p'
$MaxFrameRate      = 30          # peak cap, not enforced CFR (see 7.3.2)
$GopSize           = 250
$BFrames           = 2
$DeinterlaceFilter = 'bwdif=mode=0'

# Audio
$AudioCodec      = 'aac'
$AudioBitrate    = '192k'
$AudioSampleRate = 48000

# Filter chain (see 7.4)
$DialogueEnhance = 'dialoguenhance=original=1:enhance=1:voice=2'
$Compressor      = 'acompressor=threshold=-21dB:ratio=4:attack=20:release=250:makeup=2'
$Loudnorm        = 'loudnorm=I=-18:TP=-1.5:LRA=11'
$Limiter         = 'alimiter=limit=0.95:level=disabled'

# Container
$SubtitleCodec = 'mov_text'
$MovFlags      = '+faststart'

# Misc
$NameMaxLength = 36
$NoneKeyword   = 'none'

# ---------------------------------------------------------------------------
# 4.2 Codec classification
# ---------------------------------------------------------------------------

$TextSubtitleCodecs  = @('subrip','srt','ass','ssa','mov_text','webvtt','text')
$ImageSubtitleCodecs = @('hdmv_pgs_subtitle','dvd_subtitle','dvb_subtitle','xsub')

# ---------------------------------------------------------------------------
# Errors (3.5)
# ---------------------------------------------------------------------------

# We avoid a custom [class] because a type literal in a dot-sourced-only helper
# would not resolve at parse time in the entry points. Instead we tag an
# ordinary exception with an ExitCode in its Data dictionary; the entry point's
# catch reads it to choose the process exit code (1 = usage/validation,
# 2 = ffmpeg/ffprobe failure).
function New-NightmixError {
    param(
        [Parameter(Mandatory)][string]$Message,
        [int]$ExitCode = 1
    )
    $ex = New-Object System.Exception($Message)
    $ex.Data['ExitCode'] = $ExitCode
    return $ex
}

function Get-NightmixExitCode {
    param([Parameter(Mandatory)]$ErrorRecord)
    $code = 1
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Data -and
        $ErrorRecord.Exception.Data.Contains('ExitCode')) {
        $code = [int]$ErrorRecord.Exception.Data['ExitCode']
    }
    return $code
}

# ---------------------------------------------------------------------------
# Small parsing/formatting helpers (shared by probe and convert)
# ---------------------------------------------------------------------------

# ffprobe emits dot-decimal numbers regardless of locale; parse invariantly so
# a Russian-locale Windows does not misread "10140.000000".
function ConvertTo-InvariantDouble {
    param([Parameter(Mandatory)][string]$Value)
    return [double]::Parse(
        $Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture)
}

# True when $Object (a PSCustomObject from ConvertFrom-Json) has a non-empty
# property $Name. PS 5.1 ConvertFrom-Json returns PSCustomObject, so we test
# the property set rather than $null on a maybe-absent member.
function Test-JsonProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $false }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-JsonProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    if (Test-JsonProperty -Object $Object -Name $Name) { return $Object.$Name }
    return $null
}

# ---------------------------------------------------------------------------
# 4.3 Required functions
# ---------------------------------------------------------------------------

function Assert-Tool {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw (New-NightmixError "Required tool not found on PATH: $Name" 1)
    }
}

function Get-MediaInfo {
    param([Parameter(Mandatory)][string]$Path)

    $probeArgs = @(
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_format',
        '-show_streams',
        $Path
    )

    $output = & $FFprobePath @probeArgs
    if ($LASTEXITCODE -ne 0) {
        throw (New-NightmixError "ffprobe failed (exit $LASTEXITCODE) for: $Path" 2)
    }
    if (-not $output) {
        throw (New-NightmixError "ffprobe returned no output for: $Path" 2)
    }

    $json = ($output -join "`n")
    try {
        return ($json | ConvertFrom-Json)
    } catch {
        throw (New-NightmixError "ffprobe output could not be parsed as JSON for: $Path" 2)
    }
}

function Get-StreamsByType {
    param(
        [Parameter(Mandatory)]$MediaInfo,
        [Parameter(Mandatory)][ValidateSet('video','audio','subtitle')][string]$Type
    )
    $streams = @()
    if (Test-JsonProperty -Object $MediaInfo -Name 'streams') {
        $streams = @($MediaInfo.streams | Where-Object { $_.codec_type -eq $Type })
    }
    # Callers wrap the result in @() to guarantee an array for 0/1/many; do not
    # add a unary comma here or that @() would nest an array inside an array.
    return $streams
}

# Returns the tag value as a trimmed string, or $null when absent/blank.
function Get-StreamTag {
    param([Parameter(Mandatory)]$Stream, [Parameter(Mandatory)][string]$Name)
    if (Test-JsonProperty -Object $Stream -Name 'tags') {
        $tags = $Stream.tags
        if (Test-JsonProperty -Object $tags -Name $Name) {
            $value = "$($tags.$Name)".Trim()
            if ($value) { return $value }
        }
    }
    return $null
}

function Get-StreamLanguage {
    param([Parameter(Mandatory)]$Stream)
    $lang = Get-StreamTag -Stream $Stream -Name 'language'
    # MP4 always writes a language and defaults it to 'und' (undetermined);
    # MKV leaves it absent. Treat 'und' as absent so both render blank and
    # convert never emits a noise -metadata language=und flag.
    if ($lang -and $lang.ToLowerInvariant() -eq 'und') { return $null }
    return $lang
}

function Get-StreamTitle {
    param([Parameter(Mandatory)]$Stream)
    return (Get-StreamTag -Stream $Stream -Name 'title')
}

function Get-ChannelLayoutLabel {
    param([Parameter(Mandatory)]$Stream)

    # Prefer ffprobe's channel_layout, normalised: strip qualifiers like
    # "5.1(side)" -> "5.1" and render the two word-named layouts numerically so
    # the column reads uniformly (stereo -> 2.0), matching the probe example.
    $layout = "$(Get-JsonProperty -Object $Stream -Name 'channel_layout')".Trim()
    if ($layout) {
        $layout = ($layout -replace '\(.*?\)\s*$', '')
        switch ($layout) {
            'mono'   { return '1.0' }
            'stereo' { return '2.0' }
            default  { return $layout }
        }
    }

    $channels = 0
    $raw = Get-JsonProperty -Object $Stream -Name 'channels'
    if ($null -ne $raw) { $channels = [int]$raw }
    switch ($channels) {
        1       { return '1.0' }
        2       { return '2.0' }
        6       { return '5.1' }
        8       { return '7.1' }
        default { if ($channels -gt 0) { return "$channels ch" } else { return '' } }
    }
}

# 3.2 Output filename derivation.
function Get-SafeName {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$Extension
    )
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $name = $stem.ToLowerInvariant()
    $name = $name -replace '[^\p{L}\p{Nd}]+', '-'
    $name = $name.Trim('-')
    if ($name.Length -gt $NameMaxLength) { $name = $name.Substring(0, $NameMaxLength) }
    $name = $name.Trim('-')
    if ([string]::IsNullOrEmpty($name)) { $name = 'output' }
    $ext = $Extension.TrimStart('.')
    return "$name.$ext"
}

# 8.4 Path resolution. Inputs must exist; use LiteralPath so spaces and
# Cyrillic are safe. Returns a full absolute path for ffmpeg.
function Resolve-InputPath {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) {
        throw (New-NightmixError "File not found: $Path" 1)
    }
    return $resolved.ProviderPath
}

# 8.4 Output does not exist yet, so resolve against the current working
# directory ($PWD.ProviderPath, not the process cwd, which can diverge).
function Resolve-OutputPath {
    param([Parameter(Mandatory)][string]$Path)
    $combined = [System.IO.Path]::Combine($PWD.ProviderPath, $Path)
    return [System.IO.Path]::GetFullPath($combined)
}

# 3.3 Pretty-print an ffmpeg command for -DryRun: one argument group per line,
# copy-pasteable, never abbreviated. A "group" is a flag plus its trailing
# non-flag operands, quoting any token that needs it.
function Format-FFmpegCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($FFmpegPath)

    $current = $null
    foreach ($arg in $Arguments) {
        $token = $arg
        if ($token -match '[\s"'',;|\[\]]') { $token = '"' + $token + '"' }

        if ($arg -like '-*') {
            if ($null -ne $current) { $lines.Add('  ' + $current) }
            $current = $token
        } else {
            if ($null -ne $current) { $current = "$current $token" } else { $current = $token }
        }
    }
    if ($null -ne $current) { $lines.Add('  ' + $current) }

    return $lines.ToArray()
}

# 4.3 The single execution point for ffmpeg.
function Invoke-FFmpeg {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$DryRun
    )

    if ($DryRun) {
        Write-Plan -Lines (Format-FFmpegCommand -Arguments $Arguments)
        return
    }

    # Splat the array through the call operator so each element is passed as one
    # argument (correct quoting) rather than reassembling a command string.
    # 2>&1 merges ffmpeg's stderr (its live progress) into the pipeline so we
    # can echo it live and keep the last lines for a failure message.
    $tail = New-Object System.Collections.Generic.Queue[string]
    & $FFmpegPath @Arguments 2>&1 | ForEach-Object {
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
        [Console]::Error.WriteLine($line)
        $tail.Enqueue($line)
        while ($tail.Count -gt 20) { [void]$tail.Dequeue() }
    }
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        $detail = ($tail.ToArray() -join "`n")
        throw (New-NightmixError "ffmpeg failed (exit $code):`n$detail" 2)
    }
}

# 4.3 Consistent plan-block formatting (used by -DryRun and the real-run
# pre-flight summary).
function Write-Plan {
    param([Parameter(Mandatory)][string[]]$Lines)
    foreach ($line in $Lines) { Write-Output $line }
}
