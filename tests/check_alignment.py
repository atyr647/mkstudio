import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert('RGB')
parts=open('/tmp/align_geo.txt').read().split()
ytop=int(parts[0]); yrow=int(parts[1]); rh=int(parts[2]); cols=parts[3:]
def extent(y0,y1,x0,x1):
    # bounding box of "ink": pixels differing noticeably from the cell's background (its left-edge pixel)
    bg=im.getpixel((x0+1,y0+2)); xs=[]
    for x in range(x0+1,x1-1):
        for y in range(y0+3,y1-3):
            p=im.getpixel((x,y))
            if sum(abs(a-b) for a,b in zip(p,bg))>110: xs.append(x); break
    return (min(xs)-x0, x1-max(xs)-1) if xs else None
print("col        anchor  header(left,right inset)   cell(left,right inset)   delta")
for c in cols:
    name,x,w,anc=c.split(','); x=int(x); w=int(w)
    h=extent(ytop,ytop+rh,x,x+w); r=extent(yrow,yrow+rh,x,x+w)
    if h and r:
        d=(h[0]-r[0]) if anc=='w' else (h[1]-r[1])
        print(f"{name:8s}   {anc}       {str(h):22s}     {str(r):20s}   {d:+d}px")
