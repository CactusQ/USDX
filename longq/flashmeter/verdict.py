import sys,glob,os,importlib.util
spec=importlib.util.spec_from_file_location("a",sys.argv[2]); 
src=open(sys.argv[2]).read().split("rows=[]")[0]; ns={}; exec(src,ns); fps=ns['flashes_per_s']
keep=[];drop=[]
for f in sorted(glob.glob(sys.argv[1]+'/*.txt')):
    n=os.path.basename(f)[:-4]
    L=[l.split() for l in open(f) if l.strip()][15:]
    g=[float(r[1]) for r in L]; c=[[float(r[2+i]) for r in L] for i in range(16)]
    quads=[[sum(c[(qy*2+dy)*4+qx*2+dx][k] for dy in (0,1) for dx in (0,1))/4 for k in range(len(g))] for qy in (0,1) for qx in (0,1)]
    fg=fps(g); fq=max(fps(q) for q in quads); mean=sum(g)/len(g)
    why=[]
    if any(w in n.lower() for w in ('seizure','disorienting','strobe','flash','epilep')): why.append('name')
    if fg>1: why.append(f'full {fg}/s')
    if fq>2: why.append(f'quadrant {fq}/s')
    if mean<0.03: why.append(f'blank mean {mean:.2f}')
    (drop if why else keep).append((n,fg,fq,mean,why))
print("KEEP",len(keep)); [print(f"  full {a}/s quad {b}/s mean {m:.2f}  {n[:60]}") for n,a,b,m,_ in keep]
print("DROP",len(drop)); [print(f"  {','.join(w):28} {n[:60]}") for n,a,b,m,w in drop]
open(sys.argv[1]+'/../drop.txt','w').write('\n'.join(n for n,*_ in drop)+'\n')
