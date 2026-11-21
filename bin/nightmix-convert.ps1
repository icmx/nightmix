<#
.SYNOPSIS
Convert a video for playback on weak external hardware: decode-cheap H.264 plus
a fixed dialogue-lifting audio chain.

.DESCRIPTION
Re-encodes video to constrained-CRF H.264 (8-bit, capped resolution/frame rate)
and runs every selected audio track through a fixed filter chain that downmixes
to stereo, enhances dialogue, compresses dynamics, normalises loudness and
limits peaks. Subtitles are re-encoded to mov_text; image-based subtitles are
skipped.

Audio selection is mandatory: pass -Audio with indices, -ExtraAudio with a file,
or -Audio none for a silent output.

.PARAMETER DryRun
Print the plan and the complete ffmpeg command without running anything.
.PARAMETER Force
Allow overwriting an existing target file.
.PARAMETER VideoProfile
Key into $VideoProfiles: 'standard' (default) or 'light'.
.PARAMETER Audio
Comma-separated 0-based audio indices (e.g. "0,2"), or "none".
.PARAMETER ExtraAudio
Paths to external audio files, each added as one track.
.PARAMETER Subtitles
Comma-separated 0-based subtitle indices, "all" for every internal text subtitle,
or "none". Default: none (subtitles are opt-in).
.PARAMETER ExtraSubtitles
Paths to external subtitle files (text-based only).
.PARAMETER Deinterlace
Apply the deinterlace filter. Never automatic.
.PARAMETER OutputDirectory
Where a bare target filename lands, overriding $DefaultOutputDirectory from
config.ps1 for this run. Ignored when the target carries a path of its own.
.PARAMETER Source
Positional 0, mandatory. Input file.
.PARAMETER Target
Positional 1, mandatory. Output .mp4 path. A bare filename goes to the default
output directory if one is configured; anything with a path in it (.\out.mp4,
D:\x\out.mp4) is taken literally.

.EXAMPLE
nightmix-convert.ps1 -Audio "0" -Subtitles "1" "video.mkv" "video.mp4"
.EXAMPLE
nightmix-convert.ps1 -DryRun -Audio "0" -ExtraAudio "commentary.mka" "video.mkv" "video.mp4"
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [string]$VideoProfile,
    [string]$Audio,
    [string[]]$ExtraAudio,
    [string]$Subtitles,
    [string[]]$ExtraSubtitles,
    [switch]$Deinterlace,
    [string]$OutputDirectory,
    [Parameter(Mandatory, Position = 0)][string]$Source,
    [Parameter(Mandatory, Position = 1)][string]$Target
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Parse "-Audio"/"-Subtitles" into @{ None; All; Indices }. 'all' only with
# -AllowAll (subtitles): audio must always be chosen explicitly.
function ConvertFrom-IndexSelector {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Option,
        [switch]$AllowAll
    )

    $trimmed = $Value.Trim()
    if ($trimmed -eq 'none') { return @{ None = $true; All = $false; Indices = @() } }
    if ($AllowAll -and $trimmed -eq 'all') { return @{ None = $false; All = $true; Indices = @() } }

    $keywords = if ($AllowAll) { "'all'/'none'" } else { "'none'" }
    $parts = @($trimmed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $indices = @()
    foreach ($p in $parts) {
        if ($p -notmatch '^\d+$') {
            throw "$Option has an invalid index '$p'. Use comma-separated 0-based numbers, or $keywords."
        }
        $indices += [int]$p
    }
    return @{ None = $false; All = $false; Indices = @($indices | Sort-Object -Unique) }
}

$Notes = New-Object System.Collections.Generic.List[string]
function Add-Note { param([string]$Text) $Notes.Add($Text) }

# ffmpeg inputs, in order: source (0), then -ExtraAudio, then -ExtraSubtitles.
$InputPaths = New-Object System.Collections.Generic.List[string]

# One external file = one extra input; its first $Type stream becomes a track.
function Add-ExternalTrack {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Type)
    $abs = Resolve-InputPath $Path
    $name = [System.IO.Path]::GetFileName($abs)
    $streams = @(Get-StreamsByType -MediaInfo (Get-MediaInfo -Path $abs) -Type $Type)
    if ($streams.Count -eq 0) { throw "external $Type file has no $Type stream: $abs" }
    if ($streams.Count -gt 1) { Add-Note "Note: $name has $($streams.Count) $Type streams; using the first." }

    $title = Get-StreamTitle $streams[0]
    if (-not $title) { $title = [System.IO.Path]::GetFileNameWithoutExtension($abs) }
    $InputPaths.Add($abs)
    return @{ Input = $InputPaths.Count - 1; Stream = 0; Lang = (Get-StreamLanguage $streams[0]); Title = $title; Plan = "+ $name" }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    if (-not $VideoProfile) { $VideoProfile = $DefaultVideoProfile }
    if (-not ($VideoProfiles.Keys -contains $VideoProfile)) {
        $valid = ($VideoProfiles.Keys | Sort-Object) -join ', '
        throw "-VideoProfile '$VideoProfile' is unknown. Valid profiles: $valid."
    }
    $prof = $VideoProfiles[$VideoProfile]

    # --- Selectors ---
    $audioProvided = $PSBoundParameters.ContainsKey('Audio')

    if (-not $audioProvided -and -not $ExtraAudio) {
        throw ("no audio selected. Specify -Audio with track indices, -ExtraAudio with`n" +
            "an external file, or -Audio none for a silent output.`n" +
            "Run nightmix-probe.ps1 `"$Source`" to see the available tracks.")
    }

    $audioSel = @{ None = $false; All = $false; Indices = @() }
    if ($audioProvided) { $audioSel = ConvertFrom-IndexSelector -Value $Audio -Option '-Audio' }
    if ($audioSel.None -and $ExtraAudio) {
        throw "-Audio none cannot be combined with -ExtraAudio."
    }

    $subsProvided = $PSBoundParameters.ContainsKey('Subtitles')
    # Subtitles are opt-in: omitting -Subtitles means none.
    $subsSel = @{ None = $true; All = $false; Indices = @() }
    if ($subsProvided) { $subsSel = ConvertFrom-IndexSelector -Value $Subtitles -Option '-Subtitles' -AllowAll }

    # --- Paths ---
    $sourceAbs = Resolve-InputPath $Source

    # Resolved before the overwrite check, so -Force guards the file actually written.
    $targetAbs = Resolve-OutputPath -Path $Target -Directory $OutputDirectory
    $note = Assert-CanOverwrite -Path $targetAbs -Force:$Force -DryRun:$DryRun
    if ($note) { Add-Note $note }

    # --- Probe ---
    $info = Get-MediaInfo -Path $sourceAbs
    $srcVideo = @(Get-StreamsByType -MediaInfo $info -Type 'video')
    $srcAudio = @(Get-StreamsByType -MediaInfo $info -Type 'audio')
    $srcSubs  = @(Get-StreamsByType -MediaInfo $info -Type 'subtitle')

    if ($srcVideo.Count -eq 0) {
        throw "source has no video stream: $sourceAbs (this is not an audio converter)."
    }
    $video = $srcVideo[0]

    $durationSeconds = Get-MediaDuration $info $video   # drives progress % and ETA
    $InputPaths.Add($sourceAbs)

    # --- Output tracks: internal (index order), then external (command-line order).
    #     Each is @{ Input; Stream; Lang; Title; Plan } ---

    $audioOutputs = @()
    foreach ($idx in $audioSel.Indices) {
        if ($idx -ge $srcAudio.Count) {
            throw "-Audio requested index $idx, but the source has $($srcAudio.Count) audio track(s) (0..$([math]::Max($srcAudio.Count - 1, 0)))."
        }
        $s = $srcAudio[$idx]
        $audioOutputs += @{
            Input = 0; Stream = $idx; Lang = (Get-StreamLanguage $s); Title = (Get-StreamTitle $s)
            Plan  = ('{0}  {1} {2} {3}' -f $idx, (Get-StreamLanguage $s), (Get-ChannelLayoutLabel $s), $s.codec_name).Trim()
        }
    }
    foreach ($p in $ExtraAudio) { $audioOutputs += Add-ExternalTrack -Path $p -Type 'audio' }

    # Subtitles: image-based ones are skipped (with a note), ASS/SSA warned once.
    $subOutputs = @()
    $subPlan = @()
    $subIdxList = $subsSel.Indices
    if ($subsSel.All) {
        # Every internal TEXT subtitle; image-based ones silently excluded.
        $subIdxList = @(for ($i = 0; $i -lt $srcSubs.Count; $i++) {
            if ($TextSubtitleCodecs -contains $srcSubs[$i].codec_name) { $i }
        })
    }
    $assWarned = $false
    foreach ($idx in $subIdxList) {
        if ($idx -ge $srcSubs.Count) {
            throw "-Subtitles requested index $idx, but the source has $($srcSubs.Count) subtitle track(s) (0..$([math]::Max($srcSubs.Count - 1, 0)))."
        }
        $s = $srcSubs[$idx]
        $codec = "$($s.codec_name)"
        $left = ('{0}  {1} {2}' -f $idx, (Get-StreamLanguage $s), $codec).Trim()
        if ($TextSubtitleCodecs -notcontains $codec) {
            Add-Note "Skipping subtitle $idx ($codec): image-based, not supported in MP4."
            $subPlan += "$left  -> SKIPPED (image-based)"
            continue
        }
        if ($codec -in @('ass', 'ssa') -and -not $assWarned) {
            Add-Note "Note: subtitle $idx is $($codec.ToUpper()) - styling and positioning will be lost in mov_text."
            $assWarned = $true
        }
        $subOutputs += @{ Input = 0; Stream = $idx; Lang = (Get-StreamLanguage $s); Title = (Get-StreamTitle $s) }
        $subPlan += "$left  -> mov_text"
    }
    foreach ($p in $ExtraSubtitles) {
        $ext = [System.IO.Path]::GetExtension($p).ToLowerInvariant()
        if ($ext -in @('.sup', '.idx', '.sub')) {
            throw "external subtitle '$([System.IO.Path]::GetFileName($p))' is image-based ($ext); MP4/mov_text cannot carry it."
        }
        $t = Add-ExternalTrack -Path $p -Type 'subtitle'
        $subOutputs += $t
        $subPlan += "$($t.Plan)  -> mov_text"
    }

    # --- ffmpeg command (string[] splatted: filter_complex and Cyrillic paths
    #     would break a single command string) ---
    $ff = New-Object System.Collections.Generic.List[string]
    if ($Force) { $ff.Add('-y') }

    foreach ($ip in $InputPaths) { $ff.Add('-i'); $ff.Add($ip) }

    # Audio chain, one filter_complex branch per track. Order matters:
    if ($audioOutputs.Count -gt 0) {
        $audioChain = @(
            $StereoDownmix,     # dialoguenhance accepts stereo only (errors on 5.1)
            $DialogueEnhance,   # boosts the centre (dialogue); ffmpeg 6.0+; emits 3.0
            $StereoDownmix,     # fold that centre back into L/R: output must be true stereo
            $Compressor,        # the actual DRC; makeup is a linear multiplier, not dB
            $Loudnorm,          # average-loudness normaliser, so after the compressor
            $Limiter,           # peak ceiling; level=disabled or it undoes loudnorm
            "aresample=$AudioSampleRate"   # loudnorm outputs 192 kHz internally
        ) -join ','
        $branches = @()
        for ($n = 0; $n -lt $audioOutputs.Count; $n++) {
            $o = $audioOutputs[$n]
            $branches += ('[{0}:a:{1}]{2}[aout{3}]' -f $o.Input, $o.Stream, $audioChain, $n)
        }
        $ff.Add('-filter_complex'); $ff.Add(($branches -join ';'))
    }

    # maps: video, audio, subtitles
    $ff.Add('-map'); $ff.Add('0:v:0')
    for ($n = 0; $n -lt $audioOutputs.Count; $n++) { $ff.Add('-map'); $ff.Add("[aout$n]") }
    foreach ($o in $subOutputs) { $ff.Add('-map'); $ff.Add("$($o.Input):s:$($o.Stream)") }

    # Video filters: [deinterlace,] scale, [fps]. min() prevents upscaling.
    $sizeParts = $prof.Size -split 'x'
    $boxW = [int]$sizeParts[0]; $boxH = [int]$sizeParts[1]
    $scaleFilter = "scale='min(iw,$boxW)':'min(ih,$boxH)':force_original_aspect_ratio=decrease:force_divisible_by=2"
    $srcFps = Get-FrameRate $video
    $capped = ($null -ne $srcFps -and $srcFps -gt $MaxFrameRate)

    $vfStages = @()
    if ($Deinterlace) { $vfStages += $DeinterlaceFilter }
    $vfStages += $scaleFilter
    if ($capped) { $vfStages += "fps=$MaxFrameRate" }
    $ff.Add('-vf'); $ff.Add(($vfStages -join ','))

    # Video encoder, tuned for decode cost on weak hardware.
    $ff.AddRange([string[]]@(
        '-c:v', 'libx264',
        '-crf', "$($prof.Crf)",
        '-preset', $VideoPreset,
        '-tune', $VideoTune,                 # CAVLC, no deblocking: ~10-15% bitrate for a much cheaper decode
        '-profile:v', 'high',
        '-level', "$($prof.Level)",          # caps refs/buffers to what hardware decoders implement
        '-maxrate', "$($prof.MaxRate)",      # constrained CRF: plain CRF spikes in high motion,
        '-bufsize', "$($prof.BufSize)",      #   exactly where a weak decoder falls behind
        '-g', '250',
        '-bf', '2',                          # deep B-pyramids raise decode buffer needs
        '-pix_fmt', 'yuv420p'                # 8-bit: 10-bit is the usual outright-refusal cause
    ))

    # Only mapped streams are written, so no audio/subs needs no -an/-sn.
    if ($audioOutputs.Count -gt 0) { $ff.AddRange([string[]]@('-c:a', $AudioCodec, '-b:a', $AudioBitrate)) }
    if ($subOutputs.Count -gt 0)   { $ff.AddRange([string[]]@('-c:s', 'mov_text')) }

    # filter_complex drops source tags; copy them back. Absent tags emit no flag.
    foreach ($kind in 'a', 's') {
        $outs = @(if ($kind -eq 'a') { $audioOutputs } else { $subOutputs })
        for ($n = 0; $n -lt $outs.Count; $n++) {
            if ($outs[$n].Lang)  { $ff.Add("-metadata:s:${kind}:$n"); $ff.Add("language=$($outs[$n].Lang)") }
            if ($outs[$n].Title) { $ff.Add("-metadata:s:${kind}:$n"); $ff.Add("title=$($outs[$n].Title)") }
        }
    }

    # first output audio is default
    if ($audioOutputs.Count -gt 0) { $ff.Add('-disposition:a:0'); $ff.Add('default') }

    $ff.Add('-movflags'); $ff.Add('+faststart')
    $ff.Add($targetAbs)

    # --- Plan (dry and real runs) ---
    $plan = New-Object System.Collections.Generic.List[string]
    $plan.Add("Source:  $([System.IO.Path]::GetFileName($sourceAbs))")
    $plan.Add("Target:  $targetAbs")
    $plan.Add('')

    $srcW = $video.width
    $srcH = $video.height
    $scaleNote = '(scaling unknown)'
    $outDims = "${srcW}x${srcH}"
    if ($srcW -gt 0 -and $srcH -gt 0) {
        $factor = [Math]::Min([double]$boxW / $srcW, [double]$boxH / $srcH)
        if ($factor -ge 1) { $scaleNote = '(no scaling needed)'; $outDims = "${srcW}x${srcH}" }
        else {
            $outW = 2 * [math]::Floor(($srcW * $factor) / 2)
            $outH = 2 * [math]::Floor(($srcH * $factor) / 2)
            $outDims = "$([int]$outW)x$([int]$outH)"
            $scaleNote = "(scaled to fit ${boxW}x${boxH})"
        }
    }
    $plan.Add("Video:   ${srcW}x${srcH} -> $outDims  $scaleNote")
    $plan.Add("         $($video.codec_name) -> libx264 crf $($prof.Crf), profile $VideoProfile, cap $($prof.MaxRate)")
    $fpsNote = if ($capped) { "capped to $MaxFrameRate" } else { "under $MaxFrameRate cap, unchanged" }
    $deintNote = if ($Deinterlace) { 'deinterlace' } else { 'no deinterlace' }
    $plan.Add("         $(Format-Fps $srcFps) fps ($fpsNote), $deintNote")
    $plan.Add('')

    $plan.Add('Audio:')
    if ($audioOutputs.Count -eq 0) {
        $plan.Add('  none (silent output)')
    } else {
        for ($n = 0; $n -lt $audioOutputs.Count; $n++) {
            $o = $audioOutputs[$n]
            $line = "  $($o.Plan.PadRight(18)) -> stereo, dialogue-enhanced, $AudioCodec $AudioBitrate"
            if ($n -eq 0) { $line += '  [default]' }
            $plan.Add($line)
        }
    }
    $plan.Add('')

    $plan.Add('Subtitles:')
    if ($subPlan.Count -eq 0) {
        $plan.Add('  (none)')
    } else {
        foreach ($row in $subPlan) { $plan.Add("  $row") }
    }

    if ($Notes.Count -gt 0) { $Notes; '' }
    $plan
    ''

    Invoke-FFmpeg -Arguments $ff.ToArray() -TotalSeconds $durationSeconds -DryRun:$DryRun

    if (-not $DryRun) { "Done. -> $targetAbs" }
    exit 0
} catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit 1
}
