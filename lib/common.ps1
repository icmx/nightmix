# Shared constants and helpers. Dot-sourced by the bin/ scripts; never run directly.
# Don't tune values here - override them in config.ps1 (loaded at the end).

# Cyrillic track titles from ffprobe and Cyrillic paths need UTF-8.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------------------
# Configuration
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
$MaxFrameRate      = 30          # peak cap, not forced CFR: 23.976 stays 23.976
$GopSize           = 250
$BFrames           = 2
$DeinterlaceFilter = 'bwdif=mode=0'

# Audio
$AudioCodec      = 'aac'
$AudioBitrate    = '192k'
$AudioSampleRate = 48000

# Audio filter chain, applied to every selected track. See the chain in
# nightmix-convert.ps1 for the order and why it matters; config.example.ps1
# explains the two knobs worth tuning ($Compressor, $Loudnorm).
$StereoDownmix   = 'aformat=channel_layouts=stereo'
$DialogueEnhance = 'dialoguenhance=original=1:enhance=1:voice=2'
$Compressor      = 'acompressor=threshold=-21dB:ratio=4:attack=20:release=250:makeup=2'
$Loudnorm        = 'loudnorm=I=-18:TP=-1.5:LRA=11'
$Limiter         = 'alimiter=limit=0.95:level=disabled'

# Container
$SubtitleCodec = 'mov_text'
$MovFlags      = '+faststart'

# Where a bare target filename lands; unset = current directory. See
# Resolve-OutputPath.
$DefaultOutputDirectory = $null

# Misc
$NoneKeyword   = 'none'
$AllKeyword    = 'all'

# Subtitle codecs that convert to mov_text. Anything else (PGS, VOBSUB, unknown)
# is treated as image-based and skipped: feeding it to mov_text aborts the mux.
$TextSubtitleCodecs  = @('subrip','srt','ass','ssa','mov_text','webvtt','text')
$ImageSubtitleCodecs = @('hdmv_pgs_subtitle','dvd_subtitle','dvb_subtitle','xsub')

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

# Exit code rides in the exception's Data (1 = usage/validation, 2 = ffmpeg/ffprobe).
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
# Probing, paths, ffmpeg
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
    # Array position is the per-type index. Callers wrap in @(); no unary comma
    # here, or that @() would nest an array inside an array.
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
    # MP4 defaults to 'und'; MKV leaves it absent. Treat both as absent.
    if ($lang -and $lang.ToLowerInvariant() -eq 'und') { return $null }
    return $lang
}

function Get-StreamTitle {
    param([Parameter(Mandatory)]$Stream)
    return (Get-StreamTag -Stream $Stream -Name 'title')
}

function Get-ChannelLayoutLabel {
    param([Parameter(Mandatory)]$Stream)

    # Prefer ffprobe's channel_layout: "5.1(side)" -> "5.1", stereo -> 2.0.
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

# Every path handed to ffmpeg is made absolute first: $PWD and the process cwd
# can diverge, so a relative path may resolve elsewhere in the child process.
function Resolve-InputPath {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) {
        throw (New-NightmixError "File not found: $Path" 1)
    }
    return $resolved.ProviderPath
}

# Does this output argument carry a path (a separator anywhere, or drive-relative
# 'C:out.mp4'), or is it a bare filename?
function Test-PathHasDirectory {
    param([Parameter(Mandatory)][string]$Path)
    # IndexOfAny, not a regex: a character class holding a backslash is a
    # quoting trap that fails silently (it matches only the slash).
    if ($Path.IndexOfAny([char[]]@([System.IO.Path]::DirectorySeparatorChar,
                                   [System.IO.Path]::AltDirectorySeparatorChar)) -ge 0) { return $true }
    return [bool]($Path -match '^[A-Za-z]:')
}

# -Directory (-OutputDirectory or $DefaultOutputDirectory) applies ONLY to a bare
# filename; '.\out.mp4', 'sub\out.mp4', 'D:\x\out.mp4' are taken literally, so
# '.\' means "here". A missing directory is an error, never a silent mkdir.
function Resolve-OutputPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Directory
    )

    $base = $PWD.ProviderPath

    if ($Directory -and -not (Test-PathHasDirectory $Path)) {
        if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
            throw (New-NightmixError ("output directory does not exist: $Directory`n" +
                "Create it, or give the target a path of its own (.\$Path writes to the current directory).") 1)
        }
        $base = (Resolve-Path -LiteralPath $Directory).ProviderPath
    }

    $combined = [System.IO.Path]::Combine($base, $Path)
    return [System.IO.Path]::GetFullPath($combined)
}

# Pretty-print an ffmpeg command for -DryRun: copy-pasteable, one flag plus its
# operands per line.
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

# Seconds from an ffmpeg "HH:MM:SS.micro" timestamp; $null if unparseable.
function ConvertTo-SecondsFromHms {
    param([string]$Value)
    if ($Value -notmatch '^(\d+):([0-5]\d):([0-5]\d(?:\.\d+)?)$') { return $null }
    return ([double]$Matches[1] * 3600 + [double]$Matches[2] * 60 + (ConvertTo-InvariantDouble $Matches[3]))
}

function Format-Hms {
    param([double]$Seconds)
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { $Seconds = 0 }
    $ts = [System.TimeSpan]::FromSeconds([math]::Floor($Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

# Progress flags injected by Invoke-FFmpeg. -nostats/-loglevel silence the
# stream dumps, the x264 options wall and the closing statistics; -progress
# emits a machine-readable key=value stream we render ourselves.
$ProgressFlags = @('-nostats', '-loglevel', 'error', '-progress', 'pipe:1')

# Progress keys we consume silently; anything else on the stream is real log
# output. Listed explicitly so a genuine error line is never swallowed.
$ProgressKeyPattern = '^(frame|fps|bitrate|total_size|out_time_us|out_time_ms|dup_frames|drop_frames|stream_[0-9_]+q)='

# The single execution point for ffmpeg. Silences ffmpeg and renders one
# progress line from its -progress stream; $TotalSeconds (source duration)
# adds percentage and ETA. -DryRun prints the command, progress flags included.
function Invoke-FFmpeg {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [double]$TotalSeconds = 0,
        [switch]$DryRun
    )

    $full = @($ProgressFlags + $Arguments)

    if ($DryRun) {
        Write-Plan -Lines (Format-FFmpegCommand -Arguments $full)
        return
    }

    # Under 'Stop', 2>&1 turns ffmpeg's first stderr line into a terminating
    # error. Failure is detected via $LASTEXITCODE instead.
    $ErrorActionPreference = 'Continue'

    $tail      = New-Object System.Collections.Generic.Queue[string]
    $speed     = ''
    $lastShown = -1.0
    $painted   = $false
    $live      = -not [Console]::IsErrorRedirected   # repaint in place vs plain lines

    & $FFmpegPath @full 2>&1 | ForEach-Object {
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }

        if ($line -match '^speed=\s*(.+?)\s*$') {
            $v = $Matches[1]   # N/A until ffmpeg has a measurement
            $speed = if ($v -match '^[0-9.]+x$') { $v } else { '' }
            return
        }
        if ($line -match '^out_time=(.+?)\s*$') {
            $secs = ConvertTo-SecondsFromHms $Matches[1]
            if ($null -eq $secs) { return }

            $text = ''
            if ($TotalSeconds -gt 0) {
                $pct = [math]::Min(100, [int][math]::Floor($secs * 100 / $TotalSeconds))
                $text = ('[{0,3}%]  {1} / {2}' -f $pct, (Format-Hms $secs), (Format-Hms $TotalSeconds))
            } else {
                $text = ('         {0}' -f (Format-Hms $secs))
            }
            if ($speed) { $text += "   speed $speed" }

            $rate = 0.0
            if ($speed -match '^([0-9.]+)x$') { $rate = [double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) }
            if ($TotalSeconds -gt 0 -and $rate -gt 0) {
                $text += ('   eta {0}' -f (Format-Hms (($TotalSeconds - $secs) / $rate)))
            }

            if ($live) {
                [Console]::Error.Write("`r" + $text.PadRight(76))
                $painted = $true
            } else {
                # Redirected: a plain line every 5% (or every media minute).
                $mark = if ($TotalSeconds -gt 0) { [math]::Floor($secs * 20 / $TotalSeconds) } else { [math]::Floor($secs / 60) }
                if ($mark -gt $lastShown) {
                    [Console]::Error.WriteLine($text.Trim())
                    $lastShown = $mark
                }
            }
            return
        }
        if ($line -match '^progress=\s*(.+?)\s*$') {
            # ffmpeg's last block lands a hair under the full duration, so the
            # 100% step never fires on its own — close it out explicitly.
            if ($Matches[1] -eq 'end' -and $TotalSeconds -gt 0) {
                $final = ('[{0,3}%]  {1} / {2}' -f 100, (Format-Hms $TotalSeconds), (Format-Hms $TotalSeconds))
                if ($live) { [Console]::Error.Write("`r" + $final.PadRight(76)); $painted = $true }
                else { [Console]::Error.WriteLine($final) }
            }
            return
        }
        if ($line -match $ProgressKeyPattern) { return }

        # Anything else is genuine log/error output.
        if ($painted) { [Console]::Error.WriteLine(''); $painted = $false }
        [Console]::Error.WriteLine($line)
        $tail.Enqueue($line)
        while ($tail.Count -gt 20) { [void]$tail.Dequeue() }
    }
    $code = $LASTEXITCODE

    if ($painted) { [Console]::Error.WriteLine('') }

    if ($code -ne 0) {
        $detail = ($tail.ToArray() -join "`n")
        throw (New-NightmixError "ffmpeg failed (exit $code):`n$detail" 2)
    }
}

function Write-Plan {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    foreach ($line in $Lines) { Write-Output $line }
}

# Local overrides: dot-sourced last so they win; absent is fine.
$NightmixConfigPath = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', 'config.ps1'))

if (Test-Path -LiteralPath $NightmixConfigPath) {
    . $NightmixConfigPath
}

