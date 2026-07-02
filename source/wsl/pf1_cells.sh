#!/bin/bash
# Show non-blank PF1 text cells (char layer) from a MAME capture, with row/col.
# Cell low16 = {colour[15:12], tile[11:0]}; blank tile = 0x000. Stride = 64 cols.
cd /path/to/nightslashers/mame-dump/caps
for F in "$@"; do
  echo "=== ${F} pf1 non-blank (idx, row=idx/64 col=idx%64, cell, tile=low12, ascii) ==="
  tr -d '\r' < "${F}_pf1.hex" | awk '{
    v=substr($0,5,4);
    if(v!="0000"){
      i=NR-1; tile=("0x" v)%4096; ch=tile%128;
      a=(ch>=32 && ch<127)? sprintf("%c",ch) : ".";
      printf "  idx=%4d r=%2d c=%2d  cell=%s tile=%03x ascii=%s\n", i,int(i/64),i%64,v,tile,a
    }
  }'
done
