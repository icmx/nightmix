<#
.SYNOPSIS
Convert a video for playback on weak external hardware: decode-cheap H.264 plus
a fixed dialogue-lifting audio chain.

.DESCRIPTION
Re-encodes video to constrained-CRF H.264 (8-bit, capped resolution/frame rate)
and runs every selected audio track through a fixed filter chain that downmixes
to stereo, enhances dialogue, compresses dynamics, normalises loudness and
limits peaks. Subtitles are re-encoded to mov_text; image-based subtitles are
skipped. See docs/spec.md section 7.

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
.PARAMETER Source
Positional 0, mandatory. Input file.
.PARAMETER Target
Positional 1, mandatory. Output .mp4 path.

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
    [Parameter(Mandatory, Position = 0)][string]$Source,
    [Parameter(Mandatory, Position = 1)][string]$Target
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\common.ps1')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Parse a "-Audio"/"-Subtitles" selector into
# @{ None = bool; All = bool; Indices = int[] }.
# 'all' is only accepted with -AllowAll (subtitles); audio must be chosen
# explicitly, so it has no bulk keyword.
function ConvertFrom-IndexSelector {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Option,
        [switch]$AllowAll
    )

    $trimmed = $Value.Trim()
    if ($trimmed -ieq $NoneKeyword) { return @{ None = $true; All = $false; Indices = @() } }
    if ($AllowAll -and $trimmed -ieq $AllKeyword) { return @{ None = $false; All = $true; Indices = @() } }

    $keywords = if ($AllowAll) { "'$AllKeyword'/'$NoneKeyword'" } else { "'$NoneKeyword'" }
    $parts = @($trimmed -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $indices = @()
    foreach ($p in $parts) {
        if ($p -eq '-1') {
            throw (New-NightmixError "$Option -1 is not valid. Use '$Option $NoneKeyword' for no streams of this type." 1)
        }
        if ($p -notmatch '^\d+$') {
            throw (New-NightmixError "$Option has an invalid index '$p'. Use comma-separated 0-based numbers, or $keywords." 1)
        }
        $indices += [int]$p
    }
    return @{ None = $false; All = $false; Indices = @($indices | Sort-Object -Unique) }
}

# Numeric frame rate from an "num/den" fraction; $null if unparseable.
function Get-FrameRateValue {
    param([string]$RFrameRate)
    if (-not $RFrameRate) { return $null }
    $p = $RFrameRate -split '/'
    if ($p.Count -ne 2) { return $null }
    $den = [double]$p[1]
    if ($den -eq 0) { return $null }
    return ([double]$p[0] / $den)
}

function Format-Fps {
    param($Value)
    if ($null -eq $Value) { return '?' }
    return ([math]::Round($Value, 3)).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

$Notes = New-Object System.Collections.Generic.List[string]
function Add-Note { param([string]$Text) $Notes.Add($Text) }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

try {
    # --- 0. Resolve defaults / static config ---
    if (-not $VideoProfile) { $VideoProfile = $DefaultVideoProfile }
    if (-not ($VideoProfiles.Keys -contains $VideoProfile)) {
        $valid = ($VideoProfiles.Keys | Sort-Object) -join ', '
        throw (New-NightmixError "-VideoProfile '$VideoProfile' is unknown. Valid profiles: $valid." 1)
    }
    $prof = $VideoProfiles[$VideoProfile]

    # --- 1. Validate tools ---
    Assert-Tool $FFmpegPath
    Assert-Tool $FFprobePath

    # --- 1a. Parse selectors ---
    $audioProvided = $PSBoundParameters.ContainsKey('Audio')
    $hasExtraAudio = ($ExtraAudio -and $ExtraAudio.Count -gt 0)
    $hasExtraSubs  = ($ExtraSubtitles -and $ExtraSubtitles.Count -gt 0)

    if (-not $audioProvided -and -not $hasExtraAudio) {
        throw (New-NightmixError (
            "no audio selected. Specify -Audio with track indices, -ExtraAudio with`n" +
            "an external file, or -Audio $NoneKeyword for a silent output.`n" +
            "Run nightmix-probe.ps1 `"$Source`" to see the available tracks.") 1)
    }

    $audioSel = @{ None = $false; All = $false; Indices = @() }
    if ($audioProvided) { $audioSel = ConvertFrom-IndexSelector -Value $Audio -Option '-Audio' }
    if ($audioSel.None -and $hasExtraAudio) {
        throw (New-NightmixError "-Audio $NoneKeyword cannot be combined with -ExtraAudio." 1)
    }

    $subsProvided = $PSBoundParameters.ContainsKey('Subtitles')
    # Subtitles are opt-in: omitting -Subtitles means none. Use -Subtitles all
    # for every internal text subtitle.
    $subsSel = @{ None = $true; All = $false; Indices = @() }
    if ($subsProvided) { $subsSel = ConvertFrom-IndexSelector -Value $Subtitles -Option '-Subtitles' -AllowAll }

    # --- 1b. Resolve source and target paths ---
    $sourceAbs = Resolve-InputPath $Source

    $targetAbs = Resolve-OutputPath $Target

    $targetExists = Test-Path -LiteralPath $targetAbs
    if ($targetExists -and -not $Force) {
        # A real run refuses to overwrite; a -DryRun still previews the command.
        if (-not $DryRun) {
            throw (New-NightmixError "target already exists: $targetAbs (use -Force to overwrite)." 1)
        }
        Add-Note "Note: target exists; a real run would need -Force to overwrite it."
    }

    # --- 2. Probe source ---
    $info = Get-MediaInfo -Path $sourceAbs
    $srcVideo = @(Get-StreamsByType -MediaInfo $info -Type 'video')
    $srcAudio = @(Get-StreamsByType -MediaInfo $info -Type 'audio')
    $srcSubs  = @(Get-StreamsByType -MediaInfo $info -Type 'subtitle')

    if ($srcVideo.Count -eq 0) {
        throw (New-NightmixError "source has no video stream: $sourceAbs (this is not an audio converter)." 1)
    }
    $video = $srcVideo[0]

    # Source duration drives the progress percentage/ETA (ffmpeg's own output
    # reports elapsed media time but never the total).
    $durationSeconds = 0
    $durRaw = Get-JsonProperty -Object $info.format -Name 'duration'
    if (-not $durRaw) { $durRaw = Get-JsonProperty -Object $video -Name 'duration' }
    if ($durRaw) { try { $durationSeconds = ConvertTo-InvariantDouble "$durRaw" } catch { $durationSeconds = 0 } }

    # --- 2a. Validate internal audio indices ---
    if (-not $audioSel.None) {
        foreach ($idx in $audioSel.Indices) {
            if ($idx -ge $srcAudio.Count) {
                $hi = [math]::Max($srcAudio.Count - 1, 0)
                throw (New-NightmixError "-Audio requested index $idx, but the source has $($srcAudio.Count) audio track(s) (0..$hi)." 1)
            }
        }
    }

    # --- 2b. Validate internal subtitle indices (explicit only) ---
    if ($subsProvided -and -not $subsSel.None -and -not $subsSel.All) {
        foreach ($idx in $subsSel.Indices) {
            if ($idx -ge $srcSubs.Count) {
                $hi = [math]::Max($srcSubs.Count - 1, 0)
                throw (New-NightmixError "-Subtitles requested index $idx, but the source has $($srcSubs.Count) subtitle track(s) (0..$hi)." 1)
            }
        }
    }

    # --- 2c. Build the ordered input list (6): source, extra audio, extra subs ---
    $inputPaths = New-Object System.Collections.Generic.List[string]
    $inputPaths.Add($sourceAbs)

    $extraAudioInfos = @()
    foreach ($p in @($ExtraAudio | Where-Object { $_ })) {
        $abs = Resolve-InputPath $p
        $eInfo = Get-MediaInfo -Path $abs
        $eAudio = @(Get-StreamsByType -MediaInfo $eInfo -Type 'audio')
        if ($eAudio.Count -eq 0) {
            throw (New-NightmixError "external audio file has no audio stream: $abs" 1)
        }
        if ($eAudio.Count -gt 1) {
            Add-Note "Note: $([System.IO.Path]::GetFileName($abs)) has $($eAudio.Count) audio streams; using the first."
        }
        $inputIndex = $inputPaths.Count
        $inputPaths.Add($abs)
        $extraAudioInfos += @{
            InputIndex = $inputIndex
            Abs        = $abs
            FileName   = [System.IO.Path]::GetFileName($abs)
            Stem       = [System.IO.Path]::GetFileNameWithoutExtension($abs)
            First      = $eAudio[0]
        }
    }

    $extraSubInfos = @()
    foreach ($p in @($ExtraSubtitles | Where-Object { $_ })) {
        $abs = Resolve-InputPath $p
        $ext = [System.IO.Path]::GetExtension($abs).ToLowerInvariant()
        if ($ext -in @('.sup', '.idx', '.sub')) {
            throw (New-NightmixError "external subtitle '$([System.IO.Path]::GetFileName($abs))' is image-based ($ext); MP4/mov_text cannot carry it." 1)
        }
        $eInfo = Get-MediaInfo -Path $abs
        $eSubs = @(Get-StreamsByType -MediaInfo $eInfo -Type 'subtitle')
        if ($eSubs.Count -eq 0) {
            throw (New-NightmixError "external subtitle file has no subtitle stream: $abs" 1)
        }
        $inputIndex = $inputPaths.Count
        $inputPaths.Add($abs)
        $extraSubInfos += @{
            InputIndex = $inputIndex
            Abs        = $abs
            FileName   = [System.IO.Path]::GetFileName($abs)
            Stem       = [System.IO.Path]::GetFileNameWithoutExtension($abs)
            First      = $eSubs[0]
        }
    }

    # --- 3. Resolve selections into concrete output tracks ---

    # Audio outputs: internal (index order) then external (command-line order).
    $audioOutputs = @()
    if (-not $audioSel.None) {
        foreach ($idx in $audioSel.Indices) {
            $s = $srcAudio[$idx]
            $audioOutputs += @{
                Kind      = 'internal'
                InputIndex = 0
                SrcIndex  = $idx
                Lang      = (Get-StreamLanguage $s)
                Title     = (Get-StreamTitle $s)
                PlanLeft  = ('{0}  {1} {2} {3}' -f $idx, (Get-StreamLanguage $s), (Get-ChannelLayoutLabel $s), (Get-JsonProperty -Object $s -Name 'codec_name')).Trim()
            }
        }
    }
    foreach ($ea in $extraAudioInfos) {
        $title = Get-StreamTitle $ea.First
        if (-not $title) { $title = $ea.Stem }
        $audioOutputs += @{
            Kind      = 'external'
            InputIndex = $ea.InputIndex
            SrcIndex  = 0
            Lang      = (Get-StreamLanguage $ea.First)
            Title     = $title
            PlanLeft  = ('+ {0}' -f $ea.FileName)
        }
    }

    # Subtitle outputs + plan rows (image subs skipped; ass warned once).
    $subOutputs = @()
    $subPlan = @()
    $assWarned = $false
    if (-not $subsSel.None) {
        if ($subsSel.All) {
            # 'all' means every internal TEXT subtitle. Image-based ones can
            # never go into MP4, so they are simply not eligible here — no
            # per-track warning, since the user asked for a bulk selection.
            $subIdxList = @()
            for ($i = 0; $i -lt $srcSubs.Count; $i++) {
                $c = "$(Get-JsonProperty -Object $srcSubs[$i] -Name 'codec_name')"
                if ($TextSubtitleCodecs -contains $c) { $subIdxList += $i }
            }
        } else {
            $subIdxList = $subsSel.Indices
        }

        foreach ($idx in $subIdxList) {
            $s = $srcSubs[$idx]
            $codec = "$(Get-JsonProperty -Object $s -Name 'codec_name')"
            $isImage = -not ($TextSubtitleCodecs -contains $codec)
            if ($isImage) {
                # Only reachable for explicitly requested indices; 'all' filtered
                # image codecs out above.
                Add-Note "Skipping subtitle $idx ($codec): image-based, not supported in MP4."
                $subPlan += ('{0}  {1} {2}' -f $idx, (Get-StreamLanguage $s), $codec).Trim() + '  -> SKIPPED (image-based)'
                continue
            }
            if (($codec -eq 'ass' -or $codec -eq 'ssa') -and -not $assWarned) {
                Add-Note "Note: subtitle $idx is $($codec.ToUpper()) - styling and positioning will be lost in mov_text."
                $assWarned = $true
            }
            $subOutputs += @{
                Kind = 'internal'; InputIndex = 0; SrcIndex = $idx
                Lang = (Get-StreamLanguage $s); Title = (Get-StreamTitle $s)
            }
            $subPlan += ('{0}  {1} {2}' -f $idx, (Get-StreamLanguage $s), $codec).Trim() + '  -> mov_text'
        }
    }
    foreach ($es in $extraSubInfos) {
        $title = Get-StreamTitle $es.First
        if (-not $title) { $title = $es.Stem }
        $subOutputs += @{
            Kind = 'external'; InputIndex = $es.InputIndex; SrcIndex = 0
            Lang = (Get-StreamLanguage $es.First); Title = $title
        }
        $subPlan += ('+ {0}  -> mov_text' -f $es.FileName)
    }

    # --- 5. Build the ffmpeg command (string[] to splat) ---
    $ff = New-Object System.Collections.Generic.List[string]
    # (banner and stream dumps are suppressed by the -loglevel flag Invoke-FFmpeg adds)
    if ($targetExists -and $Force) { $ff.Add('-y') }

    foreach ($ip in $inputPaths) { $ff.Add('-i'); $ff.Add($ip) }

    # filter_complex (audio only)
    if ($audioOutputs.Count -gt 0) {
        $audioChain = @(
            $StereoDownmix,                 # downmix to stereo (dialoguenhance needs stereo in)
            $DialogueEnhance,
            $StereoDownmix,                 # fold enhanced centre back into L/R (dialoguenhance emits 3.0)
            $Compressor,
            $Loudnorm,
            $Limiter,
            "aresample=$AudioSampleRate"
        ) -join ','
        $branches = @()
        for ($n = 0; $n -lt $audioOutputs.Count; $n++) {
            $o = $audioOutputs[$n]
            $branches += ('[{0}:a:{1}]{2}[aout{3}]' -f $o.InputIndex, $o.SrcIndex, $audioChain, $n)
        }
        $ff.Add('-filter_complex'); $ff.Add(($branches -join ';'))
    }

    # maps: video, audio, subtitles
    $ff.Add('-map'); $ff.Add('0:v:0')
    if ($audioOutputs.Count -gt 0) {
        for ($n = 0; $n -lt $audioOutputs.Count; $n++) { $ff.Add('-map'); $ff.Add("[aout$n]") }
    }
    foreach ($so in $subOutputs) {
        if ($so.Kind -eq 'internal') { $ff.Add('-map'); $ff.Add("0:s:$($so.SrcIndex)") }
        else { $ff.Add('-map'); $ff.Add("$($so.InputIndex):s:0") }
    }

    # video filter chain: [deinterlace,] scale, [fps]
    $sizeParts = $prof.Size -split 'x'
    $boxW = [int]$sizeParts[0]; $boxH = [int]$sizeParts[1]
    $scaleFilter = "scale='min(iw,$boxW)':'min(ih,$boxH)':force_original_aspect_ratio=decrease:force_divisible_by=2"
    $srcFps = Get-FrameRateValue (Get-JsonProperty -Object $video -Name 'r_frame_rate')
    $capped = ($null -ne $srcFps -and $srcFps -gt $MaxFrameRate)

    $vfStages = @()
    if ($Deinterlace) { $vfStages += $DeinterlaceFilter }
    $vfStages += $scaleFilter
    if ($capped) { $vfStages += "fps=$MaxFrameRate" }
    $ff.Add('-vf'); $ff.Add(($vfStages -join ','))

    # video encoder
    $ff.AddRange([string[]]@(
        '-c:v', $VideoCodec,
        '-crf', "$($prof.Crf)",
        '-preset', $VideoPreset,
        '-tune', $VideoTune,
        '-profile:v', $H264Profile,
        '-level', "$($prof.Level)",
        '-maxrate', "$($prof.MaxRate)",
        '-bufsize', "$($prof.BufSize)",
        '-g', "$GopSize",
        '-bf', "$BFrames",
        '-pix_fmt', $PixelFormat
    ))

    # audio / subtitle codecs (or disable)
    if ($audioOutputs.Count -gt 0) {
        $ff.AddRange([string[]]@('-c:a', $AudioCodec, '-b:a', $AudioBitrate))
    } else {
        $ff.Add('-an')
    }
    if ($subOutputs.Count -gt 0) {
        $ff.AddRange([string[]]@('-c:s', $SubtitleCodec))
    } elseif ($subsSel.None -and -not $hasExtraSubs) {
        $ff.Add('-sn')
    }

    # metadata (copy only; absent tags emit no flag)
    for ($n = 0; $n -lt $audioOutputs.Count; $n++) {
        $o = $audioOutputs[$n]
        if ($o.Lang)  { $ff.Add("-metadata:s:a:$n"); $ff.Add("language=$($o.Lang)") }
        if ($o.Title) { $ff.Add("-metadata:s:a:$n"); $ff.Add("title=$($o.Title)") }
    }
    for ($n = 0; $n -lt $subOutputs.Count; $n++) {
        $o = $subOutputs[$n]
        if ($o.Lang)  { $ff.Add("-metadata:s:s:$n"); $ff.Add("language=$($o.Lang)") }
        if ($o.Title) { $ff.Add("-metadata:s:s:$n"); $ff.Add("title=$($o.Title)") }
    }

    # first output audio is default
    if ($audioOutputs.Count -gt 0) { $ff.Add('-disposition:a:0'); $ff.Add('default') }

    $ff.Add('-movflags'); $ff.Add($MovFlags)
    $ff.Add($targetAbs)

    # --- 4. Report the plan (both dry and real runs) ---
    $plan = New-Object System.Collections.Generic.List[string]
    $plan.Add("Source:  $([System.IO.Path]::GetFileName($sourceAbs))")
    $plan.Add("Target:  $([System.IO.Path]::GetFileName($targetAbs))")
    $plan.Add('')

    $srcW = Get-JsonProperty -Object $video -Name 'width'
    $srcH = Get-JsonProperty -Object $video -Name 'height'
    $scaleNote = '(scaling unknown)'
    $outDims = "${srcW}x${srcH}"
    if ($null -ne $srcW -and $null -ne $srcH -and $srcW -gt 0 -and $srcH -gt 0) {
        $factor = [Math]::Min([double]$boxW / $srcW, [double]$boxH / $srcH)
        if ($factor -ge 1) { $scaleNote = '(no scaling needed)'; $outDims = "${srcW}x${srcH}" }
        else {
            $outW = 2 * [math]::Floor(($srcW * $factor) / 2)
            $outH = 2 * [math]::Floor(($srcH * $factor) / 2)
            $outDims = "$([int]$outW)x$([int]$outH)"
            $scaleNote = "(scaled to fit ${boxW}x${boxH})"
        }
    }
    $srcCodec = Get-JsonProperty -Object $video -Name 'codec_name'
    $plan.Add("Video:   ${srcW}x${srcH} -> $outDims  $scaleNote")
    $plan.Add("         $srcCodec -> $VideoCodec crf $($prof.Crf), profile $VideoProfile, cap $($prof.MaxRate)")
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
            $left = $o.PlanLeft
            if ($left.Length -lt 18) { $left = $left.PadRight(18) }
            $line = "  $left -> stereo, dialogue-enhanced, $AudioCodec $AudioBitrate"
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

    # Print notes (warnings), then the plan.
    foreach ($note in $Notes) { Write-Output $note }
    if ($Notes.Count -gt 0) { Write-Output '' }
    Write-Plan -Lines $plan.ToArray()
    Write-Output ''

    # --- 6. Execute (or print command on -DryRun) ---
    Invoke-FFmpeg -Arguments $ff.ToArray() -TotalSeconds $durationSeconds -DryRun:$DryRun

    if (-not $DryRun) { Write-Output "Done. -> $targetAbs" }
    exit 0
} catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit (Get-NightmixExitCode $_)
}
