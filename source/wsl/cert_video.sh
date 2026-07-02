#!/bin/bash
# Certify the M3 video RTL is bit-exact (handoff gate): 4 PF + 2 sprite layers + colmix.
W=/path/to/nightslashers/wsl
echo "===== 4 PLAYFIELDS (vs MAME) ====="; bash $W/run_all_layers.sh 2>&1 | grep -E "frame=|frame compare"
echo "===== SPRITE spr0 (gfx3 5bpp) ====="; bash $W/run_obj.sh 1800 spr0 2>&1 | grep "obj compare"
echo "===== SPRITE spr1 (gfx4 4bpp) ====="; bash $W/run_obj.sh 1800 spr1 2>&1 | grep "obj compare"
echo "===== COLMIX/ACE MIXER (vs ref_render) ====="; bash $W/run_colmix2.sh 1800 1 2>&1 | grep "colmix compare"
echo "===== FULL-FRAME VIDEO (4PF+2obj+colmix vs ref_render) ====="; bash $W/run_video2.sh 1800 1 2>&1 | grep -E "best offset|video compare"
