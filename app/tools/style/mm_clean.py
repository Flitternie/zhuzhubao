"""Copy PixMiniMax frames: align feet to a ground row (per frame, or one shift for all), drop specks <=30 px."""
import sys
from PIL import Image
src,prefix,n,out,name,ground,mode=sys.argv[1:8]; n=int(n); ground=int(ground)
ims=[Image.open(f'{src}/{prefix}-{i:02d}.png').convert('RGBA') for i in range(1,n+1)]
glob_dy=ground-max(im.getbbox()[3] for im in ims)
for i,im in enumerate(ims,1):
    dy=ground-im.getbbox()[3] if mode=='align' else glob_dy
    o=Image.new('RGBA',im.size); o.alpha_composite(im,(0,dy)) if dy>=0 else o.alpha_composite(im.crop((0,-dy,im.width,im.height)),(0,0))
    p=o.load(); W,H=o.size; seen=set()
    for y in range(H):
        for x in range(W):
            if p[x,y][3] and (x,y) not in seen:
                st=[(x,y)]; seen.add((x,y)); c=[]
                while st:
                    a,b=st.pop(); c.append((a,b))
                    for dx in(-1,0,1):
                        for dz in(-1,0,1):
                            q=(a+dx,b+dz)
                            if 0<=q[0]<W and 0<=q[1]<H and q not in seen and p[q][3]: seen.add(q); st.append(q)
                if len(c)<=30:
                    for q in c: p[q]=(0,0,0,0)
    o.save(f'{out}/{name}-{i}.png'); print(name,i,dy,o.getbbox())
