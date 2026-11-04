"""Face clean-ups: near-black pixels inside an open mouth (next to the tongue) -> the yawn's dark
mouth pink; with --whisk x0,y0,x1,y1, dark grey whisker clumps in that box (pixels not touching
white fur) -> light whisker grey."""
import sys
from PIL import Image
lum=lambda c:0.3*c[0]+0.59*c[1]+0.11*c[2]
args=sys.argv[1:]; wb=None
if args and args[0]=='--whisk': wb=tuple(int(v) for v in args[1].split(',')); args=args[2:]
red=lambda c: c[3]>200 and c[0]>130 and c[0]-c[1]>45
for f in args:
    im=Image.open(f).convert('RGBA'); p=im.load(); W,H=im.size; nm=nw=0
    nb=lambda x,y:[p[x+dx,y+dy] for dx in(-1,0,1) for dy in(-1,0,1) if (dx or dy) and 0<=x+dx<W and 0<=y+dy<H]
    # tongue = red patches of 12+ pixels (the nose is smaller and stays as drawn)
    seen=set(); tongue=set()
    for y in range(H):
        for x in range(W):
            if (x,y) in seen or not red(p[x,y]): continue
            st=[(x,y)]; seen.add((x,y)); comp=[]
            while st:
                a,b=st.pop(); comp.append((a,b))
                for dx in(-1,0,1):
                    for dy in(-1,0,1):
                        q=(a+dx,b+dy)
                        if 0<=q[0]<W and 0<=q[1]<H and q not in seen and red(p[q]): seen.add(q); st.append(q)
            if len(comp)>=12: tongue|=set(comp)
    near=lambda x,y: any((x+dx,y+dy) in tongue for dx in(-1,0,1) for dy in(-1,0,1))
    for _ in range(3):   # grow from the tongue into the dark mouth
        hits=[(x,y) for y in range(1,H-1) for x in range(1,W-1) if p[x,y][3]>200 and lum(p[x,y])<70 and near(x,y) and all(c[3]>200 for c in nb(x,y))]
        tongue|=set(hits)
        for x,y in hits: p[x,y]=(181,53,60,p[x,y][3]); nm+=1
    if wb:
        x0,y0,x1,y1=wb
        for y in range(y0,y1+1):
            for x in range(x0,x1+1):
                c=p[x,y]
                if c[3] and max(c[:3])-min(c[:3])<30 and lum(c)<200 and not any(c2[3] and lum(c2)>215 for c2 in nb(x,y)):
                    p[x,y]=(194,185,181,min(c[3],210)); nw+=1
    im.save(f); print(f.split('/')[-1],'mouth',nm,'whisker',nw)
