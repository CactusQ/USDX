# WCAG 2.3.1-style general flash count: a flash = a pair of opposing luminance transitions,
# each >= 0.10 relative luminance with the darker side < 0.80. Fail if > 3 flashes in any 1 s.
# Checked on the whole frame and on each of 16 grid cells (6.25% of the screen each).
import sys, glob, os
def transitions(xs, thr=0.10):
    # collapse monotone runs into extremes, then count swings >= thr
    ext=[xs[0]]; d=0
    for x in xs[1:]:
        nd = (x>ext[-1]) - (x<ext[-1])
        if nd==0: continue
        if d==0 or nd==d: 
            if d==0 and len(ext)==1: ext.append(x)
            else: ext[-1]=x
            d=nd
        else: ext.append(x); d=nd
    return ext
def flashes_per_s(series, fps=30, thr=0.10):
    worst=0
    for i in range(0, max(1,len(series)-fps)):
        w=series[i:i+fps]; ext=[w[0]]
        # extremes via simple local max/min
        sw=0; lo=hi=w[0]; state=None; last=w[0]
        pivots=[w[0]]
        for x in w[1:]:
            if abs(x-pivots[-1])>=thr and min(x,pivots[-1])<0.8:
                pivots.append(x)
            elif len(pivots)>1 and ((pivots[-1]>pivots[-2] and x>pivots[-1]) or (pivots[-1]<pivots[-2] and x<pivots[-1])):
                pivots[-1]=x
        n=(len(pivots)-1)//2
        worst=max(worst,n)
    return worst
rows=[]
for f in sorted(glob.glob(sys.argv[1]+'/*.txt')):
    L=[l.split() for l in open(f) if l.strip()]
    if len(L)<60: rows.append((os.path.basename(f)[:-8],'NODATA',0,0,0)); continue
    L=L[15:]  # skip load-in
    g=[float(r[1]) for r in L]; cells=[[float(r[2+c]) for r in L] for c in range(16)]
    fg=flashes_per_s(g); fc=max(flashes_per_s(c) for c in cells)
    mean=sum(g)/len(g); dl=max(abs(g[i+1]-g[i]) for i in range(len(g)-1))
    rows.append((os.path.basename(f)[:-8], 'FAIL' if fg>3 or fc>3 else ('WARN' if fg>=2 or fc>=3 else 'ok'), fg, fc, mean, dl))
for r in sorted(rows,key=lambda r:(-r[3] if len(r)>3 else 0)):
    print(f"{r[1]:5} full {r[2]}/s cell {r[3]}/s mean {r[4]:.2f} maxstep {r[5]:.2f}  {r[0][:70]}" if len(r)>5 else r)
