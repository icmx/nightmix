# config.example.ps1
#
# Template for config.ps1 — your personal overrides of the defaults in
# lib/common.ps1. Copy it (install.ps1 does this for you) and edit the copy:
#
#     Copy-Item config.example.ps1 config.ps1
#
# config.ps1 is NOT tracked by git, so your settings survive updates and never
# turn into merge conflicts. This template IS tracked — it is documentation,
# and nightmix never reads it.
#
# It is dot-sourced at the very END of lib/common.ps1, so anything set here
# overrides the corresponding default. Every constant in section 4.1 of
# docs/spec.md can be overridden this way; the ones below are the useful ones.
#
# This is ordinary PowerShell and it is executed, in the calling script's own
# scope: put settings in it, nothing else. In particular, do not assign to
# names a script uses for its own parameters ($Source, $Target, $Audio, ...) —
# it is loaded after those are bound and would silently overwrite them.

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
# Anything carrying a path separator is always taken literally, so '.\' is how
# you say "no, right here". -OutputDirectory overrides this for a single run.
# The directory must already exist — nightmix will not create it.
#
# Leave it unset to keep the plain command-line behaviour: bare names land in
# the current directory.

# $DefaultOutputDirectory = 'E:\Video\Converted'

# ---------------------------------------------------------------------------
# Audio filter chain (docs/spec.md 7.4)
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
