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
    param([string]$Seconds)
    if (-not $Seconds) { return $null }
    try { $value = ConvertTo-InvariantDouble $Seconds } catch { return $null }
    if ($value -le 0) { return $null }
    $ts = [System.TimeSpan]::FromSeconds([math]::Floor($value))
    return ('{0}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function Format-Size {
    param([string]$Bytes)
    if (-not $Bytes) { return $null }
    try { $value = ConvertTo-InvariantDouble $Bytes } catch { return $null }
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
    $raw = Get-JsonProperty -Object $Stream -Name 'bit_rate'
    if ($null -eq $raw) { return $null }
    $text = "$raw".Trim()
    if (-not $text -or $text -eq '0') { return $null }
    try { $bps = ConvertTo-InvariantDouble $text } catch { return $null }
    if ($bps -le 0) { return $null }
    return ('{0}k' -f [int][math]::Round($bps / 1000))
}

function Format-Column {
    param([string]$Value, [int]$Width)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -ge $Width) { return $Value }
    return $Value.PadRight($Width)
}

function Test-ImageSubtitle {
    param([Parameter(Mandatory)][string]$Codec)
    # Text codecs are the only ones that convert cleanly to mov_text; anything
    # else (known image codec or unrecognised) is flagged as image-based.
    return (-not ($TextSubtitleCodecs -contains $Codec))
}

function Test-DecodeUnfriendly {
    param([Parameter(Mandatory)]$VideoStream)
    $codec = "$(Get-JsonProperty -Object $VideoStream -Name 'codec_name')".ToLowerInvariant()
    $pixfmt = "$(Get-JsonProperty -Object $VideoStream -Name 'pix_fmt')".ToLowerInvariant()

    $isTenBit = ($pixfmt -match '10(le|be)')
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
    Assert-Tool $FFprobePath
    $path = Resolve-InputPath $File
    $info = Get-MediaInfo -Path $path

    $out = New-Object System.Collections.Generic.List[string]

    # --- Header + video line ---
    $out.Add([System.IO.Path]::GetFileName($path))

    $videoStreams = @(Get-StreamsByType -MediaInfo $info -Type 'video')
    if ($videoStreams.Count -eq 0) {
        $out.Add('  no video')
    } else {
        $video = $videoStreams[0]
        $tokens = @()

        $width = Get-JsonProperty -Object $video -Name 'width'
        $height = Get-JsonProperty -Object $video -Name 'height'
        if ($null -ne $width -and $null -ne $height) { $tokens += "${width}x${height}" }

        $codec = Get-JsonProperty -Object $video -Name 'codec_name'
        if ($codec) { $tokens += "$codec" }

        $fps = Format-FrameRate (Get-JsonProperty -Object $video -Name 'r_frame_rate')
        if ($fps) { $tokens += "$fps fps" }

        $durationRaw = Get-JsonProperty -Object $info.format -Name 'duration'
        if (-not $durationRaw) { $durationRaw = Get-JsonProperty -Object $video -Name 'duration' }
        $duration = Format-Duration $durationRaw
        if ($duration) { $tokens += $duration }

        $size = Format-Size (Get-JsonProperty -Object $info.format -Name 'size')
        if ($size) { $tokens += $size }

        $out.Add('  ' + ($tokens -join ', '))

        # Interlacing note.
        $fieldOrder = "$(Get-JsonProperty -Object $video -Name 'field_order')".Trim()
        if ($fieldOrder -and $fieldOrder -ne 'progressive') {
            $out.Add("  interlaced (field_order: $fieldOrder) - consider -Deinterlace")
        }

        # Decode-cost note (10-bit / HEVC / VP9 / AV1).
        $decodeNote = Test-DecodeUnfriendly -VideoStream $video
        if ($decodeNote) { $out.Add("  $decodeNote") }
    }

    # --- Audio section ---
    $out.Add('')
    $out.Add('Audio')
    $audioStreams = @(Get-StreamsByType -MediaInfo $info -Type 'audio')
    if ($audioStreams.Count -eq 0) {
        $out.Add('  (none)')
    } else {
        for ($i = 0; $i -lt $audioStreams.Count; $i++) {
            $s = $audioStreams[$i]
            $lang = Get-StreamLanguage $s
            $layout = Get-ChannelLayoutLabel $s
            $codec = "$(Get-JsonProperty -Object $s -Name 'codec_name')"
            $bitrate = Format-Bitrate $s
            $title = Get-StreamTitle $s

            $row = '  ' +
                   (Format-Column "$i" 3) +
                   (Format-Column $lang 5) +
                   (Format-Column $layout 5) +
                   (Format-Column $codec 6) +
                   (Format-Column $bitrate 7) +
                   "$title"
            $out.Add($row.TrimEnd())
        }
    }

    # --- Subtitles section ---
    $out.Add('')
    $out.Add('Subtitles')
    $subStreams = @(Get-StreamsByType -MediaInfo $info -Type 'subtitle')
    if ($subStreams.Count -eq 0) {
        $out.Add('  (none)')
    } else {
        for ($i = 0; $i -lt $subStreams.Count; $i++) {
            $s = $subStreams[$i]
            $lang = Get-StreamLanguage $s
            $codec = "$(Get-JsonProperty -Object $s -Name 'codec_name')"
            $title = Get-StreamTitle $s

            $rest = @()
            if ($title) { $rest += $title }
            if (Test-ImageSubtitle $codec) { $rest += '[image-based, will be skipped]' }
            $restText = ($rest -join '   ')

            $prefix = '  ' + (Format-Column "$i" 3) + (Format-Column $lang 5)
            if ($codec.Length -ge 8) {
                # Long codec (e.g. hdmv_pgs_subtitle) overflows the column; add a
                # fixed gap before the trailing text instead of padding.
                $row = $prefix + $codec
                if ($restText) { $row += '   ' + $restText }
            } else {
                $row = $prefix + (Format-Column $codec 8) + $restText
            }
            $out.Add($row.TrimEnd())
        }
    }

    $out | ForEach-Object { Write-Output $_ }
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit (Get-NightmixExitCode $_)
}
