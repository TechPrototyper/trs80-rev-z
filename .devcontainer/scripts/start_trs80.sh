#!/bin/bash
# TRS-80 Rev Z — start the headless emulator with the debug link on TCP 5555.
# Usage: bash .devcontainer/scripts/start_trs80.sh [rom.hex] [disk.dmk ...]

set -e

ROM="${1:-${TRS80_ROM:-}}"
if [ -z "$ROM" ] || [ ! -f "$ROM" ]; then
    for cand in \
        /workspace/roms/level2.hex \
        /workspace/roms/level2_v13.hex \
        "$HOME/roms/level2.hex"; do
        if [ -f "$cand" ]; then ROM="$cand"; break; fi
    done
fi

if [ -z "$ROM" ] || [ ! -f "$ROM" ]; then
    echo "ERROR: No ROM found."
    echo "Place your Level II ROM at /workspace/roms/level2.hex"
    echo "(see roms/README.md for provenance and identification)"
    exit 1
fi

shift 2>/dev/null || true

DISKS=""
n=0
for a in "$@"; do
    case "$a" in
        --*) break ;;
        *)   DISKS="$DISKS --disk$n=$a"; n=$((n+1)) ;;
    esac
done

echo "Starting TRS-80 Rev Z (headless, debug-tcp=5555)..."
echo "ROM: $ROM"
echo "Disks: ${DISKS:-none}"

exec /workspace/sim/emu/build/emu/Vm1_core \
    --rom="$ROM" \
    --hidden \
    --volume=0 \
    --no-sound \
    --debug-tcp=5555 \
    --throttle=0.7 \
    $DISKS
