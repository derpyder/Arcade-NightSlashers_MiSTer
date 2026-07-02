import os,sys,zlib,struct
sys.argv=['x','1800']
src=open('ref_render.py').read()
cut=src.index('# ---------- composite')
exec(src[:cut])
W,H=320,240
def save(name,pf):
    img=[bytearray(W*3) for _ in range(H)]; op=0
    for y in range(H):
        for x in range(W):
            if pf[y][x] is not None:
                R,G,B=pen(pf[y][x]); img[y][x*3]=R;img[y][x*3+1]=G;img[y][x*3+2]=B; op+=1
            else:
                img[y][x*3]=255;img[y][x*3+1]=0;img[y][x*3+2]=255
    def ch(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
    raw=b''.join(b'\x00'+bytes(r) for r in img)
    open(name,'wb').write(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',struct.pack(">IIBBBBB",W,H,8,2,0,0,0))+ch(b'IDAT',zlib.compress(raw,9))+ch(b'IEND',b''))
    print(name,"opaque px =",op)
pf1,_=render_pf('pf1'); pf2,_=render_pf('pf2'); pf3,_=render_pf('pf3'); pf4,_=render_pf('pf4')
save('pf2_only.png',pf2); save('pf3_only.png',pf3); save('pf4_only.png',pf4)
