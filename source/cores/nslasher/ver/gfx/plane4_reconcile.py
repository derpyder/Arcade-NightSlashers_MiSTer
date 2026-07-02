#!/usr/bin/env python3
# Reconcile: load verify_nonfold's OWN definitions (up to section F) and compare ITS obj0hi model
# and ITS asbuilt pen-bit-4 against the independent dense model, to find which is buggy.
import os, re
HERE = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(HERE, "verify_nonfold.py")).read()
src = src[: src.index("# (F)")]            # keep only definitions (no sweep / no verdict)
ns = {"__file__": os.path.join(HERE, "verify_nonfold.py"), "__name__": "vn"}
exec(compile(src, "verify_nonfold.py", "exec"), ns)
obj0hi_byte = ns["obj0hi_byte"]; nwi_asbuilt = ns["nwi_asbuilt"]
asbuilt_tile = ns["asbuilt_tile"]; golden_tile = ns["golden_tile"]; BA3 = ns["BA3"]

# independent dense model
ROM = "/path/to/nightslashers/roms"
rf  = lambda n: open(os.path.join(ROM, n), "rb").read()
HI  = rf("mbh-06.18c") + rf("mbh-07.19c")

print("=== does the script's obj0hi_byte match the dense mbh06+mbh07 model? ===")
mism = 0
for nwi in range(0, 0x4000):
    if obj0hi_byte(nwi) != HI[nwi]: mism += 1
print("  obj0hi_byte vs HI over nwi[0,0x4000): %d mismatches" % mism)
print("  BLOB place check: BA3[0x800000:0x800008] =", BA3[0x800000:0x800008].hex(),
      " | HI[0:8] =", HI[0:8].hex())

print("\n=== script's asbuilt pen-bit-4 vs golden pen-bit-4 (code 0x0d) ===")
g = golden_tile(0x0d); a = asbuilt_tile(0x0d)
bad4 = 0
for ry in range(16):
    gr = "".join(str((g[ry][rx]>>4)&1) for rx in range(16))
    ar = "".join(str((a[ry][rx]>>4)&1) for rx in range(16))
    if gr != ar: bad4 += sum(1 for k in range(16) if gr[k]!=ar[k])
    print("  ry%2d g=%s a=%s%s" % (ry, gr, ar, "" if gr==ar else "  DIFF"))
print("  pen-bit-4 bad = %d/256" % bad4)

print("\n=== full per-plane diff (code 0x0d) the way section F counts it ===")
pp = [0]*5
for ry in range(16):
    for rx in range(16):
        x = g[ry][rx] ^ a[ry][rx]
        for p in range(5):
            if (x>>p)&1: pp[p]+=1
print("  per-plane bad bits:", pp, " total px diff:", sum(1 for ry in range(16) for rx in range(16) if g[ry][rx]!=a[ry][rx]))
