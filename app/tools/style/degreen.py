"""Remove green chroma fringe: edge pixels with a green cast become transparent, inner ones get a neutral tint."""
import sys
from PIL import Image
for f in sys.argv[1:]:
    im=Image.open(f).convert('RGBA');p=im.load();W,H=im.size;n=0
    for y in range(H):
        for x in range(W):
            r,g,b,a=p[x,y]
            if a and g>r+8 and g>b+8:
                edge=any(not(0<=x+dx<W and 0<=y+dy<H) or p[x+dx,y+dy][3]==0 for dx,dy in((1,0),(-1,0),(0,1),(0,-1)))
                p[x,y]=(0,0,0,0) if edge or (r+g+b)/3>150 else (min(r,b),min(r,b),min(r,b),a);n+=1
    im.save(f);print(f.split('sprites/')[-1],n)
