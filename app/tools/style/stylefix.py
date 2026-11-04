"""Pull generated frames back to the approved look (colours only; shapes untouched):
  - fur: interior low-saturation pixels get the reference frames' brightness distribution
    (quantile matching on luminance; hue and warmth of each pixel kept)
  - iris: blue eye pixels are replaced by the reference iris colour at the same luminance quantile
  - pads: pink pixels inside --pads x0,y0,x1,y1 (sprite pixels) become the dark grey pad colours
usage: stylefix.py --ref a.png,b.png [--pads x0,y0,x1,y1] frame.png ..."""
import sys,bisect
from PIL import Image
args=sys.argv[1:]; refs=[]; pads=None; files=[]
i=0
while i<len(args):
    if args[i]=='--ref': refs=args[i+1].split(','); i+=2
    elif args[i]=='--pads': pads=tuple(int(v) for v in args[i+1].split(',')); i+=2
    else: files.append(args[i]); i+=1
lum=lambda c:0.3*c[0]+0.59*c[1]+0.11*c[2]
iris=lambda c: c[2]>c[0]+40 and c[2]>100
def furpx(im):
    px=im.load(); W,H=im.size; out=[]
    for y in range(1,H-1):
        for x in range(1,W-1):
            c=px[x,y]
            if c[3]<250 or max(c[:3])-min(c[:3])>40 or lum(c)<150: continue
            if all(px[x+dx,y+dy][3]>=250 for dx in(-1,0,1) for dy in(-1,0,1)): out.append((x,y))
    return out
rf=[]; ri=[]; tint={}
for f in refs:
    im=Image.open(f).convert('RGBA'); px=im.load()
    for x,y in furpx(im):
        c=px[x,y]; l=lum(c); rf.append(l)
        if c[0]-c[2]>18: continue          # tail rings / ear edges: not plain fur
        b=int(l)//6; t=tint.setdefault(b,[0,0,0,0]); t[0]+=c[0]-l; t[1]+=c[1]-l; t[2]+=c[2]-l; t[3]+=1
    ri+= [c[:3] for c in im.getdata() if c[3]>=250 and iris(c)]
rf.sort(); ri.sort(key=lum)
PAD=(92,86,92); PAD_D=(58,54,60)
for f in files:
    im=Image.open(f).convert('RGBA'); px=im.load(); W,H=im.size
    fp=furpx(im); L=sorted(lum(px[x,y]) for x,y in fp)
    nf=0
    for x,y in fp:
        c=px[x,y]; l=lum(c)
        q=bisect.bisect_left(L,l)/max(1,len(L)-1)
        t=rf[min(len(rf)-1,int(q*(len(rf)-1)))]
        # the reference's warm tint at that brightness (so fur is cream, not blue-grey)
        b=int(t)//6
        while b not in tint and b>0: b-=1
        tt=tint.get(b,[0,0,0,1])
        warm_ref=(tt[0]-tt[2])/tt[3]
        if (c[0]-c[2]) < warm_ref-3:        # cooler (bluer) than the reference: take its warm tint
            nc=tuple(max(0,min(255,round(t+tt[j]/tt[3]))) for j in range(3))
        else:                               # already warm: keep the hue, only match brightness
            k=t/max(1,l); nc=tuple(max(0,min(255,round(v*k))) for v in c[:3])
        if nc!=c[:3]: nf+=1
        px[x,y]=nc+(c[3],)
    eyes=[(x,y) for y in range(H) for x in range(W) if px[x,y][3]>=200 and iris(px[x,y])]
    E=sorted(lum(px[x,y]) for x,y in eyes)
    for x,y in eyes:
        c=px[x,y]; q=bisect.bisect_left(E,lum(c))/max(1,len(E)-1)
        px[x,y]=ri[min(len(ri)-1,int(q*(len(ri)-1)))]+(c[3],)
    npad=0
    if pads:
        x0,y0,x1,y1=pads
        for y in range(max(0,y0),min(H,y1+1)):
            for x in range(max(0,x0),min(W,x1+1)):
                c=px[x,y]
                if c[3]>200 and c[0]>170 and c[0]-c[1]>35 and c[0]-c[2]>25:
                    px[x,y]=(PAD_D if c[1]<140 else PAD)+(c[3],); npad+=1
    im.save(f); print(f.split('/')[-1],'fur',nf,'eye',len(eyes),'pad',npad)
