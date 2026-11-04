"""Tidy a sprite's silhouette (drop 1-px spikes, fill 1-px notches) and give it a soft, even grey outline."""
import sys
from PIL import Image
SOFT=(150,145,150);DARK_MIN=96
def n8(a,x,y,W,H): return sum(1 for dx in(-1,0,1) for dy in(-1,0,1) if (dx or dy) and 0<=x+dx<W and 0<=y+dy<H and a[y+dy][x+dx])
def tidy(im):
    p=im.load();W,H=im.size
    for _ in range(2):
        a=[[p[x,y][3]>0 for x in range(W)] for y in range(H)]
        for y in range(H):
            for x in range(W):
                k=n8(a,x,y,W,H)
                if a[y][x] and k<=2: p[x,y]=(0,0,0,0)
                elif not a[y][x] and k>=6:
                    nb=[p[x+dx,y+dy] for dx in(-1,0,1) for dy in(-1,0,1) if (dx or dy) and 0<=x+dx<W and 0<=y+dy<H and p[x+dx,y+dy][3]]
                    p[x,y]=max(nb,key=lambda c:sum(c[:3]))
    edge=[(x,y) for y in range(H) for x in range(W) if p[x,y][3] and any(not(0<=x+dx<W and 0<=y+dy<H) or p[x+dx,y+dy][3]==0 for dx,dy in((1,0),(-1,0),(0,1),(0,-1)))]
    for x,y in edge:
        r,g,b,_=p[x,y];v=(r+g+b)/3
        if v>200: p[x,y]=SOFT+(255,)
        elif v<DARK_MIN: k=DARK_MIN/max(1,v); p[x,y]=(min(255,int(r*k)),min(255,int(g*k)),min(255,int(b*k)),255)
        else: p[x,y]=(int(r*0.7+SOFT[0]*0.3),int(g*0.7+SOFT[1]*0.3),int(b*0.7+SOFT[2]*0.3),255)
    return im
if __name__=='__main__':
    for f in sys.argv[1:]: tidy(Image.open(f).convert('RGBA')).save(f)
