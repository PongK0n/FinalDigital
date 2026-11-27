# Independent reference model of radar_1d, written straight from the algorithm
# (not from the RTL), used to check the hardware's four sonar distances.
import re, sys
MEM="new/mem/"
cos=[int(x,16) for x in open(MEM+"cos_lut.mem").read().split()]
sin=[int(x,16) for x in open(MEM+"sin_lut.mem").read().split()]
tmap=[int(x,16) for x in open(MEM+"tile_map.mem").read().split()]
def s10(v): return v-1024 if v>=512 else v
def eff(t,l1,l2,thin):
    if t==2 and thin: return 0
    if t==3 and l1:   return 0
    if t==4 and l2:   return 0
    return t
def is_wall(t): return t in (1,2,6) or (t & 8)
def rays(px,py,pa,l1,l2,thin):
    out=[]
    for off in (0,-64,64,128):
        a=(pa+off)&255
        dx=s10(cos[a])>>1; dy=s10(sin[a])>>1
        rx,ry,m=px,py,0
        while True:
            oob=(rx>>15)&1 or (ry>>15)&1
            t=eff(tmap[((ry>>10)&31)*32+((rx>>10)&31)],l1,l2,thin)
            if oob or is_wall(t) or m==127:
                out.append((m&127)*128); break
            rx=(rx+dx)&0xFFFF; ry=(ry+dy)&0xFFFF; m+=1
    return out
bad=checked=0
for line in open(sys.argv[1]):
    d=dict(kv.split("=",1) for kv in line.split() if "=" in kv and "," not in kv)
    if d.get("st")!="1": continue
    f=int(d["f"])
    if f<12: continue                       # let the sonar fill in after start
    px,py,pa=int(d["px"]),int(d["py"]),int(d["pa"])
    l1,l2,th=int(d["l1"]),int(d["l2"]),int(d["thin"])
    exp=rays(px,py,pa,l1,l2,th)
    got=[int(d["df"]),int(d["dl"]),int(d["dr"]),int(d["db"])]
    checked+=1
    if exp!=got:
        bad+=1
        if bad<=6: print("  f=%d pose=(%d,%d,%d) model=%s rtl=%s"%(f,px,py,pa,exp,got))
print("%s: %d frames checked, %d mismatches"%(sys.argv[1],checked,bad))
