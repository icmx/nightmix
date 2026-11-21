<#
.SYNOPSIS
Print a compact, read-only summary of a media file's streams.

.DESCRIPTION
Runs ffprobe and prints a two-second-scannable report: a header line, a video
summary line (with notes for interlacing and decode-unfriendly sources), then
Audio and Subtitles sections. Per-type 0-based stream indices are printed so
they can be pasted straight into nightmix-convert.ps1.

Image-based and unrecognised subtitle codecs are flagged, because MP4 cannot
carry them and nightmix-convert.ps1 will skip them.

.PARAMETER File
Path to the media file to inspect.

.EXAMPLE
nightmix-probe.ps1 "video.mkv"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$File
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

# ---------------------------------------------------------------------------
# Report-formatting helpers (probe-specific)
# ---------------------------------------------------------------------------

function Format-FrameRate {
    param([string]$RFrameRate)
    if (-not $RFrameRate) { return $null }
    $parts = $RFrameRate -split '/'
    if ($parts.Count -ne 2) { return $null }
    $den = [double]$parts[1]
    if ($den -eq 0) { return $null }
    $fps = [double]$parts[0] / $den
    if ($fps -le 0) { return $null }
    $rounded = [math]::Round($fps, 3)
    return $rounded.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Duration {
    param($Seconds)
    $value = [double]$Seconds
    if ($value -le 0) { return $null }
    $ts = [System.TimeSpan]::FromSeconds([math]::Floor($value))
    return ('{0}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Format-Size {
    param($Bytes)
    $value = [double]$Bytes
    if ($value -le 0) { return $null }
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($value -ge 1024 -and $i -lt ($units.Count - 1)) { $value /= 1024; $i++ }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($i -eq 0) { return ([string]::Format($inv, '{0} {1}', [int]$value, $units[$i])) }
    return ([string]::Format($inv, '{0:0.0} {1}', $value, $units[$i]))
}

function Format-Bitrate {
    param([Parameter(Mandatory)]$Stream)
    $bps = [double]$Stream.bit_rate
    if ($bps -le 0) { return $null }   # absent in most MKVs
    return ('{0}k' -f [int][math]::Round($bps / 1000))
}

# Pad to $Width, but always leave at least two spaces before the next column.
function Format-Column {
    param([string]$Value, [int]$Width)
    return ($Value.PadRight($Width - 2) + '  ')
}

function Test-DecodeUnfriendly {
    param([Parameter(Mandatory)]$VideoStream)
    $codec = "$($VideoStream.codec_name)".ToLowerInvariant()

    $isTenBit = ($VideoStream.pix_fmt -match '10(le|be)')
    $isHardCodec = ($codec -in @('hevc', 'vp9', 'av1'))

    if (-not ($isTenBit -or $isHardCodec)) { return $null }

    $parts = @()
    if ($isTenBit) { $parts += '10-bit' }
    if ($isHardCodec) { $parts += $codec }
    return ('{0} - likely to stutter, convert it' -f ($parts -join ' '))
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    $path = Resolve-InputPath $File
    $info = Get-MediaInfo -Path $path

    # --- Header + video line ---
    [System.IO.Path]::GetFileName($path)

    $videoStreams = @(Get-StreamsByType -MediaInfo $info -Type 'video')
    if ($videoStreams.Count -eq 0) {
        '  no video'
    } else {
        $video = $videoStreams[0]
        $tokens = @()

        if ($video.width -and $video.height) { $tokens += "$($video.width)x$($video.height)" }
        if ($video.codec_name) { $tokens += "$($video.codec_name)" }

        $fps = Format-FrameRate $video.r_frame_rate
        if ($fps) { $tokens += "$fps fps" }

        $durationRaw = $info.format.duration
        if (-not $durationRaw) { $durationRaw = $video.duration }
        $duration = Format-Duration $durationRaw
        if ($duration) { $tokens += $duration }

        $size = Format-Size $info.format.size
        if ($size) { $tokens += $size }

        '  ' + ($tokens -join ', ')

        $fieldOrder = "$($video.field_order)".Trim()
        if ($fieldOrder -and $fieldOrder -ne 'progressive') {
            "  interlaced (field_order: $fieldOrder) - consider -Deinterlace"
        }

        $decodeNote = Test-DecodeUnfriendly -VideoStream $video
        if ($decodeNote) { "  $decodeNote" }
    }

    # --- Audio section ---
    ''
    'Audio'
    $audioStreams = @(Get-StreamsByType -MediaInfo $info -Type 'audio')
    if ($audioStreams.Count -eq 0) { '  (none)' }
    for ($i = 0; $i -lt $audioStreams.Count; $i++) {
        $s = $audioStreams[$i]
        $row = '  ' +
               (Format-Column "$i" 3) +
               (Format-Column (Get-StreamLanguage $s) 5) +
               (Format-Column (Get-ChannelLayoutLabel $s) 5) +
               (Format-Column $s.codec_name 6) +
               (Format-Column (Format-Bitrate $s) 7) +
               (Get-StreamTitle $s)
        $row.TrimEnd()
    }

    # --- Subtitles section ---
    ''
    'Subtitles'
    $subStreams = @(Get-StreamsByType -MediaInfo $info -Type 'subtitle')
    if ($subStreams.Count -eq 0) { '  (none)' }
    for ($i = 0; $i -lt $subStreams.Count; $i++) {
        $s = $subStreams[$i]
        $rest = @(Get-StreamTitle $s)
        if ($TextSubtitleCodecs -notcontains $s.codec_name) { $rest += '[image-based, will be skipped]' }

        $row = '  ' +
               (Format-Column "$i" 3) +
               (Format-Column (Get-StreamLanguage $s) 5) +
               (Format-Column $s.codec_name 8) +
               (($rest | Where-Object { $_ }) -join '   ')
        $row.TrimEnd()
    }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
