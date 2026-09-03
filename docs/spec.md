# nightmix — PowerShell toolkit specification (lean)

A small set of PowerShell scripts that prepare video files for playback on weak external hardware. Two problems:

1. **Decode load.** The hardware drops frames on demanding streams. Re-encode to something cheap to decode.
2. **Audio dynamics.** Dialogue sits far below effects/music; on a speaker that distorts past ~30% volume, dialogue is inaudible while effects clip. Fix with a fixed filter chain (downmix → lift dialogue → compress → normalise → limit).

Target: **Windows, PowerShell 5.1+, ffmpeg 6.0+** (`dialoguenhance` needs 6.0).

### Decode-load mitigations (§7.3 implements these)

| Cause | Mitigation |
| --- | --- |
| 10-bit colour (common in HEVC) | `-pix_fmt yuv420p`, 8-bit |
| HEVC / VP9 / AV1 | re-encode to H.264 |
| >1080p | downscale to fit |
| >30 fps | cap at 30 |
| Bitrate spikes | constrained CRF: `-maxrate` + `-bufsize` |
| High refs / unsupported level | `-level` cap |
| CABAC + deblocking cost | `-tune fastdecode` |

The bitrate cap matters most: plain CRF spikes in high-motion scenes, exactly where a weak decoder (or a USB stick) falls behind. `light` profile (§7.3.4) is the escalation if a file still stutters.

### Scripts

| File | Role |
| --- | --- |
| `bin/nightmix-probe.ps1` | Compact read-only stream summary. |
| `bin/nightmix-convert.ps1` | Main conversion script. |
| `bin/nightmix-dvdmux.ps1` | Rare. Muxes a DVD folder into one MKV. |
| `lib/common.ps1` | Config constants + shared functions. Dot-sourced, never run directly. |
| `install.ps1` | One-time setup: puts `bin/` on `PATH`. §8. |

---

## 2. Repository layout

```
nightmix/
  bin/  nightmix-probe.ps1  nightmix-convert.ps1  nightmix-dvdmux.ps1
  lib/  common.ps1
  install.ps1
  config.example.ps1      tracked template
  config.ps1              local overrides, gitignored (§4.4)
  README.md
```

`install.ps1` adds exactly `bin/` to `PATH` — never the repo root or `lib/`. Entry points dot-source the library:

```powershell
. (Join-Path $PSScriptRoot '..\lib\common.ps1')
```

(`$PSScriptRoot` in a `bin/` script is `bin/`, so the `..\lib` hop is required.) Runnable scripts carry the `nightmix-` prefix because they land on `PATH`; `common.ps1` does not.

---

## 3. Global conventions

### 3.1 Stream indices — per-type, 0-based

Every index (probe output, convert parameters) is per-type and 0-based, matching ffmpeg's `-map 0:a:N`. Three audio tracks → indices `0,1,2` regardless of absolute stream numbers. What probe prints pastes directly into convert. No 1-based display indices.

### 3.2 `-DryRun`

On every FS-modifying script. Prints the human-readable plan and the **complete, copy-pasteable ffmpeg command** (one arg group per line, no `...`), then executes nothing. Primary debugging tool.

### 3.3 Overwrite protection

Existing output → fail unless `-Force`. Pass `-y` to ffmpeg only after the script decides overwrite is safe, never unconditionally. `-DryRun` still previews the command when the output exists (it writes nothing); the refusal applies only to real runs.

### 3.4 Error handling

- `$ErrorActionPreference = 'Stop'` at the top of each script.
- Validate before work: tools reachable, source exists, every requested index exists, every external file exists. Report all validation problems at once where practical.
- ffmpeg non-zero exit → surface exit code + last ~20 lines of stderr.
- Exit codes: `0` success, `1` validation/usage, `2` ffmpeg failure.

### 3.5 Console output

Compact, and none of ffmpeg's own chatter. `Invoke-FFmpeg` adds `-nostats -loglevel error -progress pipe:1`, which suppresses the banner, the input/output stream dumps, the x264 options wall and the closing statistics, and emits a machine-readable `key=value` stream instead. From that we render a single status line:

```
[ 42%]  00:48:12 / 01:54:30   speed 3.1x   eta 00:21:40
```

The percentage and ETA come from the **source duration**, which `nightmix-convert.ps1` already knows from the probe and which ffmpeg's own output never shows. `nightmix-dvdmux.ps1` passes no duration and gets elapsed media time plus speed.

On a console the line is repainted in place with a carriage return; when stderr is redirected it is written as plain lines in 5% steps instead (about 20 lines whatever the length), so logs stay readable. No progress bars, no Unicode boxes.

Real errors are never hidden: only the known progress keys are consumed, everything else is echoed and kept in the failure tail. These flags are part of the command printed by `-DryRun`, so what is shown is exactly what runs.

---

## 4. `lib/common.ps1`

Only constants and functions; no top-level executable logic.

### 4.1 Configuration constants

All tunables live here — nothing tunable hardcoded in entry points.

```powershell
# Tool paths
$FFmpegPath  = 'ffmpeg'      # resolved via PATH; override with a full path
$FFprobePath = 'ffprobe'

# Video profiles — tuned for decode cost, not archival quality.
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

# Filter chain (see 7.4). Tune these in config.ps1, not here (§4.4).
$StereoDownmix   = 'aformat=channel_layouts=stereo'
$DialogueEnhance = 'dialoguenhance=original=1:enhance=1:voice=2'
$Compressor      = 'acompressor=threshold=-21dB:ratio=4:attack=20:release=250:makeup=2'
$Loudnorm        = 'loudnorm=I=-18:TP=-1.5:LRA=11'
$Limiter         = 'alimiter=limit=0.95:level=disabled'

# Container
$SubtitleCodec = 'mov_text'
$MovFlags      = '+faststart'

# Output. Unset = plain CLI behaviour (bare target lands in the cwd); see §8.4.
$DefaultOutputDirectory = $null

# Misc
$NoneKeyword   = 'none'
$AllKeyword    = 'all'
```

### 4.2 Codec classification

```powershell
$TextSubtitleCodecs  = @('subrip','srt','ass','ssa','mov_text','webvtt','text')
$ImageSubtitleCodecs = @('hdmv_pgs_subtitle','dvd_subtitle','dvb_subtitle','xsub')
```

Anything in neither list → treat as image-based (skip). Fail safe: an unknown subtitle codec into `mov_text` aborts the mux.

### 4.3 Required functions

- **`Get-MediaInfo -Path`** — runs `ffprobe -v quiet -print_format json -show_format -show_streams`, returns parsed object, throws on failure. The single point of ffprobe contact.
- **`Get-StreamsByType -MediaInfo -Type <video|audio|subtitle>`** — filters `.streams` by `codec_type`, preserving order; array position **is** the per-type index. Empty array if none.
- **`Get-StreamLanguage -Stream`** → `$Stream.tags.language` or `$null`. No placeholder — caller decides.
- **`Get-StreamTitle -Stream`** → `$Stream.tags.title` or `$null`.
- **`Get-ChannelLayoutLabel -Stream`** — prefer non-empty `channel_layout`; else map count: 1→`1.0`, 2→`2.0`, 6→`5.1`, 8→`7.1`, else `"$channels ch"`.
- **`Resolve-InputPath -Path`** / **`Resolve-OutputPath -Path [-Directory <string>]`** — §8.4. Every path to ffmpeg goes through one of these. `-Directory` redirects a bare output filename; it throws (exit 1) if that directory does not exist.
- **`Test-PathHasDirectory -Path`** — §8.4. `$true` if the argument carries a path (a separator anywhere, or the drive-relative `C:out.mp4` form), `$false` for a bare filename.
- **`Invoke-FFmpeg -Arguments <string[]> [-TotalSeconds <double>] -DryRun`** — the single ffmpeg execution point. Prepends `-nostats -loglevel error -progress pipe:1` (see §3.5) to the caller's arguments. `-DryRun`: pretty-print the whole thing (§3.2), return. Else: execute, render the progress line, echo real log output; non-zero exit → throw with code + stderr tail. `-TotalSeconds` is the source duration and enables the percentage/ETA.
- **`Write-Plan -Lines <string[]>`** — consistent formatting for the plan block (used by `-DryRun` and the real-run pre-flight summary).

### 4.4 Local overrides (`config.ps1`)

`config.example.ps1` (repo root, tracked) is a commented template. `config.ps1` is the user's copy, **gitignored**, so personal settings survive updates and never become merge conflicts. `install.ps1` creates it from the template when absent and never overwrites an existing one.

`common.ps1` dot-sources it as its **last** statement, so it can override any §4.1 constant:

```powershell
$NightmixConfigPath = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::Combine($PSScriptRoot, '..', 'config.ps1'))

if (Test-Path -LiteralPath $NightmixConfigPath) { . $NightmixConfigPath }
```

Absent config is a silent no-op — a fresh clone works without one. It is `.ps1` rather than a data format on purpose: overriding any constant is the point, and dot-sourcing needs no parser. The cost is that it executes in the entry point's own scope, **after** parameter binding, so assigning to a name a script uses as a parameter would silently overwrite the user's own argument. The template says so.

`$DefaultOutputDirectory` (§8.4) is the setting this exists for; the audio chain (§7.4) is the other expected one, since that is what gets tuned per playback device.

---

## 5. `bin/nightmix-probe.ps1`

```powershell
nightmix-probe.ps1 <file>
```

`-File` positional 0, mandatory. Read-only. Output is a compact report meant to be scanned in two seconds and have indices copied out — no JSON dump, no per-stream paragraphs. Suppress absent fields.

```
video.mkv
  1920x1080, h264, 23.976 fps, 2:49:00, 14.2 GB

Audio
  0  rus  5.1  ac3   448k   Дубляж
  1  rus  2.0  aac   128k   Авторский
  2  eng  5.1  dts   1536k

Subtitles
  0  rus  subrip
  1  rus  ass     Forced
  2  eng  subrip
  3  eng  hdmv_pgs_subtitle   [image-based, will be skipped]
```

Rules:

- Header: bare filename. Second line: resolution, codec, fps, duration `H:MM:SS`, size. No video stream → `no video`.
- fps from `r_frame_rate` (fraction like `24000/1001`), 3 decimals, trailing zeros trimmed.
- Section header only when non-empty; otherwise `Audio` / `Subtitles` then `  (none)`.
- Columns: index, language, layout, codec, bitrate, title — padded to align. **Blank column when the tag is missing** (no `und`/`unknown`/`Untitled 1`). Omit bitrate if ffprobe reports none (common in MKV), don't print `0k`.
- Append `[image-based, will be skipped]` to any subtitle in `$ImageSubtitleCodecs` or unrecognised.
- Non-progressive `field_order` → add `  interlaced (field_order: tt) — consider -Deinterlace`.
- 10-bit (`pix_fmt` has `10le`/`10be`) or HEVC/VP9/AV1 → add `  10-bit hevc — likely to stutter, convert it`.

---

## 6. `bin/nightmix-dvdmux.ps1`

```powershell
nightmix-dvdmux.ps1 [-DryRun] [-Force] [-OutputDirectory <string>] <directory> <result>
```

- `-Directory` positional 0, mandatory. Accept the folder containing `VIDEO_TS` or the `VIDEO_TS` folder itself.
- `-Result` positional 1, **mandatory**. Output `.mkv` path, resolved per §8.4.
- `-OutputDirectory` optional. Overrides `$DefaultOutputDirectory` for this run.

### 6.2 Title selection

A `VIDEO_TS` folder holds menus, trailers, logos, and the main title — don't concatenate them together.

1. Enumerate `VTS_<NN>_<M>.VOB`.
2. Group by `<NN>`.
3. **Exclude `_0.VOB`** in each group (menu/navigation, not content).
4. Sum remaining sizes per group; pick the largest group — the main title.
5. Order its files by `<M>` ascending.
6. Ignore `VIDEO_TS.VOB`, `.IFO`, `.BUP`.

No `VTS_*.VOB` → fail. Largest group < ~100 MB → warn (too small to be the main title) but proceed. Always report the decision, even on a real run:

```
Found 3 titles:
  VTS_01  4 files   6.84 GB   <- selected
  VTS_02  1 file    0.21 GB
  VTS_03  1 file    0.04 GB
```

### 6.3 Muxing

VOB is MPEG-PS (byte-concatenatable) — use the **`concat:` protocol**, not the concat demuxer:

```
ffmpeg -analyzeduration 200M -probesize 200M \
  -i "concat:D:\dvd\VIDEO_TS\VTS_01_1.VOB|D:\dvd\VIDEO_TS\VTS_01_2.VOB|..." \
  -map 0 -c copy -f matroska out.mkv
```

- Large `-analyzeduration`/`-probesize` are **required** — `concat:` probes only the start, so subtitle streams appearing later are otherwise missed.
- `-map 0` keeps everything (MPEG-2 video, all AC3/DTS, all `dvd_subtitle`).
- `-c copy` — container change only; `nightmix-convert.ps1` does the real work.
- DVD subs stay image-based (dropped later by convert; text conversion would need OCR, out of scope).

After a successful mux, remind: subtitles are VOBSUB (image-based) and will be skipped by convert; run probe on the result.

---

## 7. `bin/nightmix-convert.ps1`

Always re-encodes — no copy path.

### 7.1 Signature

```powershell
nightmix-convert.ps1 [-DryRun] [-Force] [-VideoProfile <string>]
                     [-Audio <string>] [-ExtraAudio <string[]>]
                     [-Subtitles <string>] [-ExtraSubtitles <string[]>]
                     [-Deinterlace] [-OutputDirectory <string>]
                     <source> <target>
```

| Parameter | Type | Default | Meaning |
| --- | --- | --- | --- |
| `-DryRun` | switch | off | §3.2. |
| `-Force` | switch | off | Allow overwriting target. |
| `-VideoProfile` | string | `standard` | Key into `$VideoProfiles` (`standard`/`light`). |
| `-Audio` | string | **mandatory — §7.1.2** | 0-based audio indices, e.g. `"0,2"`, or `"none"`. |
| `-ExtraAudio` | string[] | none | External audio file paths. |
| `-Subtitles` | string | `none` | 0-based subtitle indices, `"all"` for every internal text subtitle, or `"none"`. |
| `-ExtraSubtitles` | string[] | none | External subtitle file paths. |
| `-Deinterlace` | switch | off | Apply `$DeinterlaceFilter`. Never automatic. |
| `-OutputDirectory` | string | `$DefaultOutputDirectory` | Where a **bare** target filename lands (§8.4). |
| `-Source` | string | — | Positional 0, mandatory. |
| `-Target` | string | — | Positional 1, mandatory. Output `.mp4` path, resolved per §8.4. |

**7.1.1 Parsing `-Audio`/`-Subtitles`.** Whitespace around commas is fine (`"0, 2"` == `"0,2"`). `"none"` (case-insensitive, `$NoneKeyword`) means no streams of that type — must be the whole value, can't combine with indices; `-Audio "none"` + `-ExtraAudio` is contradictory → reject. `"all"` (case-insensitive, `$AllKeyword`) is accepted for `-Subtitles` only and selects every internal **text** subtitle; like `none` it must be the whole value. `-Audio` has no bulk keyword — picking audio is exactly the choice that must be explicit. Reject `-1` explicitly, pointing at `none` (a leading dash is ambiguous to the parser).

**7.1.2 Audio is mandatory.** No default. Neither `-Audio` nor `-ExtraAudio` → fail:

```
Error: no audio selected. Specify -Audio with track indices, -ExtraAudio with
an external file, or -Audio none for a silent output.
Run nightmix-probe.ps1 "video.mkv" to see the available tracks.
```

Picking audio is the one choice that can't be guessed (files carry multiple dubs + commentary). Subtitles are opt-in: omitting `-Subtitles` selects none. Pass `-Subtitles all` for every internal text subtitle, or explicit indices.

### 7.2 Order of operations

1. Validate tools, source, target, external files.
2. Probe source + each external audio file.
3. Resolve selections to concrete stream refs.
4. Report the plan.
5. Build ffmpeg command.
6. Execute via `Invoke-FFmpeg`.

Reject out-of-range indices **before** ffmpeg, showing what's available:

```
Error: -Audio requested index 3, but the source has 3 audio tracks (0..2).
```

### 7.3 Video

**7.3.1 Scaling** — fit the profile's box, preserve aspect, never upscale, keep even:

```
scale='min(iw,{W})':'min(ih,{H})':force_original_aspect_ratio=decrease:force_divisible_by=2
```

`{W}`/`{H}` from the profile's `Size`. The `min()` wrappers prevent upscaling (they shrink the box to the source when the source is smaller).

**7.3.2 Frame rate** — peak cap, not forced CFR. Evaluate `r_frame_rate`: if > `$MaxFrameRate`, append `fps=$MaxFrameRate`; else append nothing and don't pass `-r` (23.976 must stay 23.976).

**7.3.3 Deinterlacing** — only with `-Deinterlace`; prepend `$DeinterlaceFilter`. Never inferred. Filter order (omit unused stages): `bwdif=mode=0 , scale=... , fps=30`. Passed as `-vf`, kept out of `filter_complex` so `-DryRun` stays readable.

**7.3.4 Encoder flags** — from profile + constants:

```
-c:v libx264 -crf {profile.Crf} -preset veryfast -tune fastdecode
-profile:v high -level {profile.Level}
-maxrate {profile.MaxRate} -bufsize {profile.BufSize}
-g 250 -bf 2 -pix_fmt yuv420p
```

Decode-cost notes:

- `-tune fastdecode` → CAVLC over CABAC, no deblocking/weighted-pred. ~10–15% bitrate cost, big decoder saving.
- `-maxrate`/`-bufsize` → constrained CRF. `bufsize` = 2×`maxrate` = a two-second window: flattens spikes without hurting quality.
- `-level 4.0` constrains refs/buffers to what mainstream hardware decoders implement.
- `-pix_fmt yuv420p` forces 8-bit — 10-bit is the most common outright-refusal cause.
- `-g 250 -bf 2` keep the GOP conventional; deep B-pyramids raise decode buffer needs.

`-movflags +faststart`. No video stream → fail (not an audio converter).

### 7.4 Audio

**Every selected track — internal and external — goes through the full chain.** No pass-through. One `filter_complex` branch per track:

```
[<input>:a:<idx>]
  aformat=channel_layouts=stereo,
  dialoguenhance=original=1:enhance=1:voice=2,
  aformat=channel_layouts=stereo,
  acompressor=threshold=-21dB:ratio=4:attack=20:release=250:makeup=2,
  loudnorm=I=-18:TP=-1.5:LRA=11,
  alimiter=limit=0.95:level=disabled,
  aresample=48000
[aout<n>]
```

Order matters — do not reorder:

1. `aformat=...stereo` **first** — `dialoguenhance` accepts stereo only, errors on 5.1.
2. `dialoguenhance` — boosts the centre-panned (dialogue) component. Needs ffmpeg 6.0+. **Emits 3.0**: it splits the enhanced dialogue out into a centre channel.
3. `aformat=...stereo` **again** — fold that centre back into L/R so the output is true stereo (the target hardware is stereo). Without this second downmix the output is 3.0, which defeats the stereo goal and may not play on weak hardware. The rest of the chain then operates on the final stereo signal.
4. `acompressor` — the actual DRC. `makeup=2` is a linear multiplier (≈ +6 dB, not a dB value); without it compression only makes things quieter.
5. `loudnorm` — average-loudness normaliser (not a compressor — hence after `acompressor`). Single-pass dynamic mode. Too loud overall → lower `I=` to `-20`, not the limiter.
6. `alimiter` — hard peak ceiling. `level=disabled` matters: it otherwise auto-levels and partially undoes `loudnorm`.
7. `aresample=48000` — **required**: `loudnorm` dynamic mode outputs 192 kHz internally, which otherwise propagates to the encoder.

Encoder: `-c:a aac -b:a 192k` per track.

**7.4.1 Metadata.** `filter_complex` drops source tags — copy them back (else tracks are nameless). **Copy only, no detection/guessing.**

- Internal: copy `language` and `title` from the source stream. Tag absent → **emit no `-metadata` flag** (no `und`/`Untitled`; players already show "Track 2").
- External: copy from the external file's probe; no title → use the **filename stem** as title; no language.

```
-metadata:s:a:0 language=rus
-metadata:s:a:0 title=Дубляж
```

Same rules for subtitle metadata.

**7.4.2 External audio.** Each `-ExtraAudio` file is an extra input; use its **first** audio stream (`:a:0`), warn if it has more. Output order: internal tracks in index order, then externals in command-line order. First output audio track → `-disposition:a:0 default`. `-Audio none` → `-an`, no branches.

### 7.5 Subtitles

MP4 carries text subs only:

- Codec in `$TextSubtitleCodecs` → re-encode to `mov_text`.
- Codec in `$ImageSubtitleCodecs` or unrecognised → **skip + warn** (`Skipping subtitle 3 (hdmv_pgs_subtitle): image-based, not supported in MP4.`) even if explicitly requested. Don't fail — attempting the copy is what crashes the mux.
- `ass`/`ssa` selected → warn once that styling/positioning is lost in `mov_text`.

External subs: each `-ExtraSubtitles` file is an extra input, mapped `:s:0` → `mov_text`. Reject image-based external subs (`.sup`, `.idx`/`.sub`) at validation. Metadata per §7.4.1. Output order: internal in index order, then externals. `-c:s mov_text`. `-Subtitles none` (and omitting `-Subtitles`) → `-sn`. `-Subtitles all` selects every internal text subtitle; image-based ones are not eligible and are excluded without a per-track warning, since the request was a bulk one. Zero subs left after skipping is fine — omit `-c:s`, don't fail.

### 7.6 Input numbering

Inputs: source `0`, then `-ExtraAudio` files, then `-ExtraSubtitles` files, in order supplied. Build this list once; derive all `-map` and `filter_complex` labels from it.

### 7.7 Plan output (dry and real runs)

`Source` is the bare filename; `Target` is the **resolved absolute path**, because with a default output directory in play the destination is no longer obvious from the command line.

```
Source:  Sample Video (2014) 1080p.mkv
Target:  E:\Video\Converted\sample-video.mp4

Video:   1920x1080 -> 1920x1080  (no scaling needed)
         h264 -> libx264 crf 22, profile standard, cap 8M
         23.976 fps (under 30 cap, unchanged), no deinterlace

Audio:   0  rus 5.1 ac3   -> stereo, dialogue-enhanced, aac 192k  [default]
         2  eng 5.1 dts   -> stereo, dialogue-enhanced, aac 192k
         + commentary.mka -> stereo, dialogue-enhanced, aac 192k

Subs:    0  rus subrip    -> mov_text
         3  eng pgs       -> SKIPPED (image-based)
```

### 7.8 Worked example

`nightmix-convert.ps1 -Audio "0" -Subtitles "0" -ExtraAudio "commentary.mka" video.mkv video.mp4`:

```
ffmpeg -nostats
  -loglevel error
  -progress pipe:1
  -i "video.mkv"
  -i "commentary.mka"
  -filter_complex "[0:a:0]aformat=channel_layouts=stereo,dialoguenhance=original=1:enhance=1:voice=2,aformat=channel_layouts=stereo,acompressor=threshold=-21dB:ratio=4:attack=20:release=250:makeup=2,loudnorm=I=-18:TP=-1.5:LRA=11,alimiter=limit=0.95:level=disabled,aresample=48000[aout0];[1:a:0]aformat=channel_layouts=stereo,dialoguenhance=original=1:enhance=1:voice=2,aformat=channel_layouts=stereo,acompressor=threshold=-21dB:ratio=4:attack=20:release=250:makeup=2,loudnorm=I=-18:TP=-1.5:LRA=11,alimiter=limit=0.95:level=disabled,aresample=48000[aout1]"
  -map 0:v:0 -map "[aout0]" -map "[aout1]" -map 0:s:0
  -vf "scale='min(iw,1920)':'min(ih,1080)':force_original_aspect_ratio=decrease:force_divisible_by=2"
  -c:v libx264 -crf 22 -preset veryfast -tune fastdecode
  -profile:v high -level 4.0 -maxrate 8M -bufsize 16M -g 250 -bf 2 -pix_fmt yuv420p
  -c:a aac -b:a 192k
  -c:s mov_text
  -metadata:s:a:0 language=rus -metadata:s:a:0 title=Дубляж
  -metadata:s:a:1 title=commentary
  -metadata:s:s:0 language=rus
  -disposition:a:0 default
  -movflags +faststart
  "video.mp4"
```

Output audio track 1 has a title but no `language` (external file had none, nothing guessed).

---

## 8. Installation and invocation

### 8.1 Usage model

Scripts live in a git repo; videos live elsewhere. Workflow: `cd` to the video, call by name; output lands in the current directory. Repo location never typed.

```powershell
cd "E:\Video\Sample"
nightmix-probe.ps1 "video.mkv"
nightmix-convert.ps1 -Audio "0" -Subtitles "1" "video.mkv" "video.mp4"
```

Setting `$DefaultOutputDirectory` (§4.4) changes only the last line's destination: results collect in one place while the `cd`-to-the-source workflow stays. `.\video.mp4` opts out for a single call.

### 8.2 `install.ps1`

One-time (rerun after moving the repo):

1. **Add `bin/` to user `PATH`**, no admin, idempotent (detect + replace a stale entry, never append twice). `bin/` only.
1. **Create `config.ps1`** from `config.example.ps1` if it is absent; never overwrite an existing one, never delete it on `-Uninstall`.

   ```powershell
   $binPath = Join-Path $PSScriptRoot 'bin'
   $current = [Environment]::GetEnvironmentVariable('Path', 'User')
   if ($current -notlike "*$binPath*") {
       [Environment]::SetEnvironmentVariable('Path', "$current;$binPath", 'User')
   }
   ```

2. **Check execution policy** — on `Restricted`/`AllSigned`, print the fix (`Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`) rather than failing later. Don't change it automatically.
3. **Verify `ffmpeg`/`ffprobe`** resolve and print version, checking ≥ 6.0 (`dialoguenhance`). Warn, don't abort, if inconclusive.
4. **Print next steps**, noting the new `PATH` needs a fresh PowerShell window.

Provide `-Uninstall` to remove `bin/` from `PATH`.

Optional (documented, off by default): add `.PS1` to `PATHEXT` to drop the `.ps1`; or, if scoop is present, register `scoop shim` aliases (`nmprobe`, `nmconvert`) instead of the `PATH` edit — one or the other, not both.

### 8.4 Path resolution (common breakage)

- `$PSScriptRoot` locates `lib/common.ps1` and `config.ps1` only — never resolve user paths against it.
- All user paths (`-Source`, `-Target`, `-ExtraAudio`, `-ExtraSubtitles`, `-Directory`) are relative to the **current working directory**, with the one exception below.
- **Make every path absolute before ffmpeg.** `$PWD` and the .NET process cwd can diverge, so a relative path PowerShell resolves fine may resolve elsewhere in a child process. Use `(Resolve-Path $p).Path` for existing inputs, `[IO.Path]::GetFullPath((Join-Path $PWD $p))` for the not-yet-existing output. (Helpers in §4.3.)

**Default output directory.** The exception, and it applies to outputs only (`-Target`, `-Result`) — never to inputs. The effective directory is `-OutputDirectory`, else `$DefaultOutputDirectory` (§4.4), else none. When one is in effect:

| Target argument | Resolves to |
| --- | --- |
| `out.mp4` (bare filename) | `<directory>\out.mp4` |
| `.\out.mp4` | current directory |
| `sub\out.mp4` | `<cwd>\sub\out.mp4` |
| `D:\x\out.mp4` | exactly that |
| `C:out.mp4` (drive-relative) | taken literally — treated as carrying a path |

The **shape of the argument** is the opt-in, not a separate switch: `.\` is already what a person types to mean "here", and a script passing a full path keeps working unchanged. With no directory in effect the first row falls back to the current directory — plain CLI behaviour.

A configured directory that does not exist is an error (exit 1), not a silent `mkdir`: creating directories is a side effect nobody asked for. Resolution happens **before** the overwrite check (§3.3), so `-Force` can never guard one file and overwrite another.

### 8.5 README

Short: what it does (both problems), prereqs (Windows, PS 5.1+, ffmpeg 6.0+ via scoop), `install.ps1`, the §8.1 example, a pointer to `config.ps1` for tuning and for the default output directory, and a "still dropping frames? → `-VideoProfile light`" note.

---

## 9. Implementation notes (gotchas)

- **Quoting.** Build ffmpeg args as a **`string[]`** and splat — never one big string PowerShell splits. `filter_complex` (`,;[]'`) and Cyrillic/space paths are the traps; test a path with both a space and a comma.
- **Console encoding.** `[Console]::OutputEncoding = [Text.Encoding]::UTF8` in `common.ps1` so Cyrillic titles (and now Cyrillic output filenames) display.
- **ffprobe JSON.** PS 5.1 `ConvertFrom-Json` → `PSCustomObject`; test presence via `$s.PSObject.Properties.Name -contains 'tags'`, not `$null` on a maybe-absent property.
- **Fractions.** `r_frame_rate` like `"24000/1001"` — parse and divide, guard `0` denominator.
- **Duration.** Prefer `format.duration`, fall back to the video stream's.
- **ffmpeg progress.** Parse `out_time` (`HH:MM:SS.micro`), not `out_time_ms` — despite its name that key reports microseconds. `speed=` is `N/A` until ffmpeg has a measurement, and the final block lands a hair under the full duration, so the 100% step has to be emitted explicitly on `progress=end`.
- **Regex.** `\p{L}`/`\p{Nd}` work in .NET regex (`-replace`). `'Тестовая Запись (2014)' -replace '[^\p{L}\p{Nd}]+', '-'` behaves per §3.2.
- Keep filter-chain and `-map` construction as separate, eyeball-able functions. Add comment-based help to each entry point.

---

## 10. Acceptance checklist

- Probe on 3 audio + 4 subtitle tracks prints indices that paste into convert and work; flags image subs, interlacing, 10-bit/HEVC; missing tags render blank (no `und`/`Untitled`).
- Convert `-DryRun` prints a complete copy-pasteable command.
- No `-Audio`/`-ExtraAudio` → §7.1.2 failure, nothing encoded. `-Audio -1` → rejected, points at `none`.
- 720p not upscaled to 1080p; 4K downscaled with aspect kept; 23.976 stays, 60 → 30; output within `maxrate` over any 2 s; 10-bit HEVC → 8-bit H.264; `-VideoProfile light` → 720p/level 3.1.
- PGS index → warn + skip, not crash. `-Audio none` → video-only MP4.
- Omitting `-Subtitles` yields `-sn` (no subtitle streams); `-Subtitles all` includes every internal text subtitle and excludes image-based ones.
- Internal + external audio both get the full chain; tags survive, absent tags emit no flag; tagless external gets filename-stem title; output audio is 48 kHz not 192 kHz.
- A source whose path contains Cyrillic characters and spaces converts successfully.
- dvdmux `-DryRun` picks the main title and lists VOBs in order.
- With no `config.ps1` present every script still runs, and a bare target lands in the current directory. With `$DefaultOutputDirectory` set, `out.mp4` lands there, `.\out.mp4` and `D:\x\out.mp4` do not, and `-OutputDirectory` beats the configured value. A directory that does not exist fails with exit 1 before anything is written. Both plans print the resolved absolute `Target`.
- After install + new terminal, all three scripts run from an unrelated drive; running install twice doesn't duplicate the `PATH` entry; `lib/` is not on `PATH`.
```
