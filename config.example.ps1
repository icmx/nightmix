# Template for config.ps1 - your overrides of the defaults in lib/common.ps1.
# install.ps1 copies it for you; config.ps1 is gitignored, this template is not
# read by nightmix. Any constant from lib/common.ps1 can be overridden; the ones
# below are the useful ones.
#
# It runs as PowerShell in the calling script's scope, after parameters are
# bound: don't assign to parameter names ($Source, $Target, $Audio, ...).

# ---------------------------------------------------------------------------
# Default output directory
# ---------------------------------------------------------------------------
#
# Where results go when the target is a BARE FILENAME with no path in it:
#
#     nightmix-convert.ps1 -Audio 0 in.mkv out.mp4        -> <this directory>
#     nightmix-convert.ps1 -Audio 0 in.mkv .\out.mp4      -> current directory
#     nightmix-convert.ps1 -Audio 0 in.mkv D:\x\out.mp4   -> exactly there
#
# -OutputDirectory overrides this for a single run. The directory must already
# exist. Unset: bare names land in the current directory.

# $DefaultOutputDirectory = 'E:\Video\Converted'

# ---------------------------------------------------------------------------
# Audio filter chain
# ---------------------------------------------------------------------------
#
# Level and character are separate knobs:
#
#   loudnorm I=    the final loudness, and the only thing that decides how far
#                  you turn the playback device up. 1 unit = 1 dB.
#   acompressor    how hard quiet dialogue is pulled up towards loud effects.
#                  Its makeup gain does NOT change the final level — loudnorm
#                  re-normalises afterwards — only the amount of compression.
#
# Defaults (lib/common.ps1) are broadcast-ish: I=-18, moderate compression.
# Two tested alternatives, progressively quieter and more heavily compressed:

# $Compressor = 'acompressor=threshold=-28dB:ratio=6:attack=15:release=250:makeup=4'
# $Loudnorm   = 'loudnorm=I=-38:TP=-2:LRA=6'

# $Compressor = 'acompressor=threshold=-28dB:ratio=6:attack=15:release=250:makeup=6'
# $Loudnorm   = 'loudnorm=I=-45:TP=-2:LRA=6'

# ---------------------------------------------------------------------------
# Video
# ---------------------------------------------------------------------------
#
# $DefaultVideoProfile = 'light'    # if 'standard' always stutters on your device

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
#
# Full paths, if ffmpeg/ffprobe are not on PATH.

# $FFmpegPath  = 'C:\ffmpeg\bin\ffmpeg.exe'
# $FFprobePath = 'C:\ffmpeg\bin\ffprobe.exe'
