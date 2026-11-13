#!/bin/sh
# Renders the impulse responses gen_table.py reads, into ./grid.
# Usage: render_grid.sh <orbit.plist> <micro.plist>
#   The plists are each plugin's AU state as Live stores it (an AuPreset Buffer,
#   hex-decoded), e.g. from a set with one Orbit and one MICRO on a track.
set -e
cd "$(dirname "$0")"
ORBIT=$1 MICRO=$2
swiftc -O -target x86_64-apple-macos12 aurender.swift -o aurender_x86  # Orbit is Intel only
python3 -c '
import numpy as np, struct
sr=48000; x=np.zeros((sr//2,2),np.float32); x[2400,:]=0.5; d=x.astype("<f4").tobytes()
open("impulse.wav","wb").write(b"RIFF"+struct.pack("<I",36+len(d))+b"WAVEfmt "+struct.pack("<IHHIIHH",16,3,2,sr,sr*8,8,32)+b"data"+struct.pack("<I",len(d))+d)'
mkdir -p grid
{
  add() { echo "$ORBIT grid/o_$1.wav $2 param_clarity=$3"; echo "$MICRO grid/m_$1.wav $2 param_focus=100 param_hrtf_selection=1"; }
  for a in $(seq -180 15 165); do for e in -90 -60 -30 0 30 60 90; do for w in 0 25 50 75 100; do for c in 0 25 50 75 100; do
    add "a${a}_e${e}_w${w}_c${c}" "param_azimuth=$a param_elevation=$e param_width=$w param_reflection_enable=0" $c
  done; done; done; done
  for a in 0 45 90 135; do
    for l in -10 0 10; do for r in 0 4; do
      add "rev_a${a}_l${l}_r${r}" "param_azimuth=$a param_elevation=30 param_width=50 param_reflection_enable=1 param_reflection_level=$l param_reflection_room=$r param_reflection_size=10" 0
    done; done
    add "rev_a${a}_off" "param_azimuth=$a param_elevation=30 param_width=50 param_reflection_enable=0" 0
  done
} | xargs -P 8 -L 1 sh -c 'arch -x86_64 ./aurender_x86 "$0" impulse.wav "$@" >/dev/null 2>&1 || echo "FAILED $1"'
echo "now: python3 gen_table.py . ../../Sources/DeviceConverter/OrbitGainTable.swift"
