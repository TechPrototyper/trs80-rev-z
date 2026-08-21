#!/bin/sh
# TRS-80 Rev Z — emulator launcher with sensible defaults.
#
#   sim/emu/run.sh                          boot to Level II BASIC
#   sim/emu/run.sh nd80aj6.dmk              boot a disk (up to 4 positional
#   sim/emu/run.sh sys.dmk data.dmk ...     images become --disk0..3)
#   sim/emu/run.sh game.dmk --skin=green    every --option passes through and
#                                           overrides the defaults below
#
# Defaults (each one is only a starting point — later options win):
#   ROM           $TRS80_ROM, else the first hit in a short candidate list
#   Skin          $TRS80_SKIN   (default grey; "none" for the plain window)
#   Keyboard      $TRS80_KBD    (default us; QWERTZ users want de)
#   Throttle      $TRS80_THROTTLE (default 0.7 — near the current ~0.75x
#                 ceiling, pinned so the audio pitch stays rock steady)
#   Drive sounds  trs80gp's own recordings when the app is installed
#                 (loaded in place from its Resources directory)
#
# The repo ships no ROMs (see roms/README.md): point TRS80_ROM at your own
# Level II image in $readmemh hex format.

set -e
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/build/emu/Vm1_core"

if [ ! -x "$bin" ]; then
    echo "run.sh: building emulator first (make -C $here)..." >&2
    make -C "$here" >/dev/null
fi

rom="${TRS80_ROM:-}"
if [ -z "$rom" ]; then
    for cand in \
        "$HOME/Projects/fpga-trs80/roms/level2_v13.hex" \
        "$here/../../roms/level2.hex" \
        "$HOME/trs80/level2.hex"; do
        if [ -f "$cand" ]; then rom="$cand"; break; fi
    done
fi
if [ -z "$rom" ]; then
    echo "run.sh: no ROM found — set TRS80_ROM=/path/to/level2.hex" >&2
    exit 1
fi

# trs80gp's drive-sound recordings, if the app is around
drives=""
gp="/Applications/trs80gp.app/Contents/Resources"
if [ -f "$gp/loaded-spin.wav" ]; then
    drives="--drive-sounds=$gp"
fi

# positional args (no leading --) become --disk0..3
set -- "$@"
disks=""
n=0
for a in "$@"; do
    case "$a" in
    --*) break ;;
    *)   disks="$disks --disk$n=$a"; n=$((n+1)); shift ;;
    esac
done

exec "$bin" \
    --rom="$rom" \
    --skin="${TRS80_SKIN:-grey}" \
    --kbd="${TRS80_KBD:-us}" \
    --throttle="${TRS80_THROTTLE:-0.7}" \
    $drives \
    $disks \
    "$@"
