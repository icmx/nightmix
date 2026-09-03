# lib/common.ps1
#
# Shared configuration constants and helper functions for the nightmix toolkit.
# Dot-sourced by the bin/ entry points; never run directly.
#
# See docs/spec.md sections 4, 7.4, 8.4 and 9.

# Cyrillic track titles from ffprobe and Cyrillic paths need UTF-8.
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
#
# Alternative options for compressor/loudnorm
# $Compressor      = 'acompressor=threshold=-28dB:ratio=6:attack=15:release=250:makeup=6'
# $Loudnorm        = 'loudnorm=I=-45:TP=-2:LRA=6'
#
$StereoDownmix   = 'aformat=channel_layouts=stereo'
$DialogueEnhance = 'dialoguenhance=original=1:enhance=1:voice=2'
$Compressor      = 'acompressor=threshold=-28dB:ratio=6:attack=15:release=250:makeup=4'
$Loudnorm        = 'loudnorm=I=-38:TP=-2:LRA=6'
$Limiter         = 'alimiter=limit=0.95:level=disabled'

# Container
$SubtitleCodec = 'mov_text'
$MovFlags      = '+faststart'

# Misc
$NoneKeyword   = 'none'
$AllKeyword    = 'all'

# ---------------------------------------------------------------------------
# 4.2 Codec classification
# ---------------------------------------------------------------------------

$TextSubtitleCodecs  = @('subrip','srt','ass','ssa','mov_text','webvtt','text')
$ImageSubtitleCodecs = @('hdmv_pgs_subtitle','dvd_subtitle','dvb_subtitle','xsub')

# ---------------------------------------------------------------------------
# Errors (3.4)
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

# 4.3 The single execution point for ffmpeg.
#
# Quietens ffmpeg and drives a compact one-line readout from its -progress
# stream. $TotalSeconds (the source duration, which ffmpeg's own output never
# shows) turns that into a percentage and an ETA; omit it and the line falls
# back to elapsed media time plus speed.
function Invoke-FFmpeg {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [double]$TotalSeconds = 0,
        [switch]$DryRun
    )

    # The progress flags are part of the command we print, so -DryRun shows
    # exactly what a real run executes.
    $full = @($ProgressFlags + $Arguments)

    if ($DryRun) {
        Write-Plan -Lines (Format-FFmpegCommand -Arguments $full)
        return
    }

    # Splat the array through the call operator so each element is passed as one
    # argument (correct quoting) rather than reassembling a command string.
    #
    # 2>&1 merges stderr into the pipeline. Under $ErrorActionPreference =
    # 'Stop' (set by the entry points) that would wrap ffmpeg's first stderr
    # line in a terminating NativeCommandError and abort. Force 'Continue'
    # locally; real failure is detected via $LASTEXITCODE below.
    $ErrorActionPreference = 'Continue'

    $tail      = New-Object System.Collections.Generic.Queue[string]
    $speed     = ''
    $lastShown = -1.0
    $painted   = $false
    # Overwrite one line in place on a console; when redirected, emit occasional
    # plain lines instead so logs stay readable.
    $live      = -not [Console]::IsErrorRedirected

    & $FFmpegPath @full 2>&1 | ForEach-Object {
        $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }

        if ($line -match '^speed=\s*(.+?)\s*$') {
            # ffmpeg reports speed=N/A until it has a measurement; show nothing
            # rather than "speed N/A".
            $v = $Matches[1]
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
                # Redirected: emit occasional plain lines instead of repainting.
                # Step by 5% when the total is known (~20 lines whatever the
                # length), otherwise once a minute of media time.
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

# 4.3 Consistent plan-block formatting (used by -DryRun and the real-run
# pre-flight summary).
function Write-Plan {
    # AllowEmptyString so blank separator lines in a plan are permitted; a
    # Mandatory [string[]] otherwise rejects any array containing an empty string.
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Lines)
    foreach ($line in $Lines) { Write-Output $line }
}
