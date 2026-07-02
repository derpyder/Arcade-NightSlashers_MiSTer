#!/bin/bash
# Determine if the get_hsub fix changed the tilemap render: revert to committed, run, compare xx count.
J=/path/to/nightslashers/jtcores
T=$J/cores/nslasher/hdl/jtnslasher_tilemap.v
F=$J/cores/nslasher/ver/gfx/frame_pxl.hex
cp "$T" /tmp/tilemap_fixed.v
cd "$J" && git checkout -- cores/nslasher/hdl/jtnslasher_tilemap.v
echo "reverted tilemap to committed (HEAD). running run_tilemap..."
bash /path/to/nightslashers/wsl/run_tilemap.sh > /tmp/rt.log 2>&1
echo "ORIGINAL (committed) tilemap render -> xx count: $(grep -c '^xx' "$F")"
cp /tmp/tilemap_fixed.v "$T"
echo "restored the get_hsub-fixed tilemap"
