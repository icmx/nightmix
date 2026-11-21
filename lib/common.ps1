# Shared constants and helpers. Dot-sourced by the bin/ scripts; never run directly.
# Don't tune values here - override them in config.ps1 (loaded at the end).
#
# Note: [double]"1.5" and "$x" are culture-invariant in PowerShell; only -f and
# .ToString() follow the current (possibly ru-RU, comma-decimal) culture.

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
# Probing
# ---------------------------------------------------------------------------

# ffprobe's own error (if any) goes straight to the console via stderr.
function Get-MediaInfo {
    param([Parameter(Mandatory)][string]$Path)
    $json = & $FFprobePath -v error -print_format json -show_format -show_streams $Path
    if ($LASTEXITCODE -ne 0) { throw "ffprobe failed for: $Path" }
    return (($json -join "`n") | ConvertFrom-Json)
}

# Array position is the per-type index. Callers wrap the result in @().
function Get-StreamsByType {
    param(
        [Parameter(Mandatory)]$MediaInfo,
        [Parameter(Mandatory)][ValidateSet('video','audio','subtitle')][string]$Type
    )
    return ($MediaInfo.streams | Where-Object { $_.codec_type -eq $Type })
}

# Trimmed tag value, or $null when absent/blank. Tag names are case-insensitive.
function Get-StreamTag {
    param([Parameter(Mandatory)]$Stream, [Parameter(Mandatory)][string]$Name)
    $value = "$($Stream.tags.$Name)".Trim()
    if ($value) { return $value }
    return $null
}

function Get-StreamLanguage {
    param([Parameter(Mandatory)]$Stream)
    $lang = Get-StreamTag $Stream 'language'
    if ($lang -eq 'und') { return $null }   # MP4's default; MKV leaves it absent
    return $lang
}

# MKV stores a track title as 'title'; MP4 stores it as 'name'.
function Get-StreamTitle {
    param([Parameter(Mandatory)]$Stream)
    $title = Get-StreamTag $Stream 'title'
    if (-not $title) { $title = Get-StreamTag $Stream 'name' }
    return $title
}

function Get-ChannelLayoutLabel {
    param([Parameter(Mandatory)]$Stream)

    # Prefer ffprobe's channel_layout: "5.1(side)" -> "5.1", stereo -> 2.0.
    $layout = "$($Stream.channel_layout)" -replace '\(.*?\)\s*$', ''
    switch ($layout) {
        ''       { break }
        'mono'   { return '1.0' }
        'stereo' { return '2.0' }
        default  { return $layout }
    }

    switch ([int]$Stream.channels) {
        0       { return '' }
        1       { return '1.0' }
        2       { return '2.0' }
        6       { return '5.1' }
        8       { return '7.1' }
        default { return "$($Stream.channels) ch" }
    }
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Every path handed to ffmpeg is made absolute first: $PWD and the process cwd
# can diverge, so a relative path may resolve elsewhere in the child process.
function Resolve-InputPath {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolved) { throw "File not found: $Path" }
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
            throw ("output directory does not exist: $Directory`n" +
                "Create it, or give the target a path of its own (.\$Path writes to the current directory).")
        }
        $base = (Resolve-Path -LiteralPath $Directory).ProviderPath
    }

    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $Path))
}

# ---------------------------------------------------------------------------
# ffmpeg
# ---------------------------------------------------------------------------

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

function Format-Hms {
    param([double]$Seconds)
    $ts = [System.TimeSpan]::FromSeconds([math]::Floor([math]::Max(0, $Seconds)))
    return ('{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

# -nostats/-loglevel silence ffmpeg's banner, stream dumps and statistics;
# -progress writes key=value blocks to stdout, which we render ourselves.
$ProgressFlags = @('-nostats', '-loglevel', 'error', '-progress', 'pipe:1')

# The single execution point for ffmpeg. Renders one progress line from the
# -progress stream; $TotalSeconds (source duration) adds percentage and ETA.
# -DryRun prints the command, progress flags included.
function Invoke-FFmpeg {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [double]$TotalSeconds = 0,
        [switch]$DryRun
    )

    $full = @($ProgressFlags + $Arguments)

    if ($DryRun) { return (Format-FFmpegCommand -Arguments $full) }

    # Under 'Stop', 2>&1 turns ffmpeg's first stderr line into a terminating
    # error. Failure is detected via $LASTEXITCODE instead.
    $ErrorActionPreference = 'Continue'

    $tail      = New-Object System.Collections.Generic.Queue[string]
    $secs      = 0.0
    $speed     = ''
    $lastShown = -1.0
    $painted   = $false
    $live      = -not [Console]::IsErrorRedirected   # repaint in place vs plain lines

    & $FFmpegPath @full 2>&1 | ForEach-Object {
        # stderr = genuine log/error output; stdout = progress key=value lines.
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $line = $_.ToString()
            if ($painted) { [Console]::Error.WriteLine(''); $painted = $false }
            [Console]::Error.WriteLine($line)
            $tail.Enqueue($line)
            while ($tail.Count -gt 20) { [void]$tail.Dequeue() }
            return
        }

        $key, $value = "$_" -split '=', 2
        $value = "$value".Trim()

        if ($key -eq 'out_time_us') {
            if ($value -match '^\d+$') { $secs = [double]$value / 1e6 }   # N/A at the start
        } elseif ($key -eq 'speed') {
            $speed = if ($value -match '^[0-9.]+x$') { $value } else { '' }   # N/A until measured
        } elseif ($key -eq 'progress') {
            # Each block ends with progress=continue|end. The last block lands a
            # hair under the full duration, so 'end' is reported as 100%.
            if ($value -eq 'end' -and $TotalSeconds -gt 0) { $secs = $TotalSeconds }

            if ($TotalSeconds -gt 0) {
                $pct = [math]::Min(100, [int][math]::Floor($secs * 100 / $TotalSeconds))
                $text = ('[{0,3}%]  {1} / {2}' -f $pct, (Format-Hms $secs), (Format-Hms $TotalSeconds))
            } else {
                $text = ('         {0}' -f (Format-Hms $secs))
            }
            if ($speed) {
                $text += "   speed $speed"
                $rate = [double]$speed.TrimEnd('x')
                if ($rate -gt 0 -and $TotalSeconds -gt $secs) {
                    $text += ('   eta {0}' -f (Format-Hms (($TotalSeconds - $secs) / $rate)))
                }
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
        }
    }
    $code = $LASTEXITCODE

    if ($painted) { [Console]::Error.WriteLine('') }

    if ($code -ne 0) {
        throw "ffmpeg failed (exit $code):`n$($tail.ToArray() -join "`n")"
    }
}

# Local overrides: dot-sourced last so they win; absent is fine.
$NightmixConfigPath = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', 'config.ps1'))

if (Test-Path -LiteralPath $NightmixConfigPath) {
    . $NightmixConfigPath
}
