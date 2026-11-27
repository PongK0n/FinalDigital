#!/usr/bin/env python3
"""Compare two directories of captured PPM frames pixel by pixel.
Usage: compare_frames.py <dirA> <dirB>"""
import sys, os
HUD = lambda x, y: 559 <= x <= 623 and 400 <= y <= 463
def load(p):
    t = open(p).read().split()
    return int(t[1]), int(t[2]), t[4:]
a, b = sys.argv[1], sys.argv[2]
names = sorted(f[:-4] for f in os.listdir(a) if f.endswith('.ppm'))
fail = False
for n in names:
    pa, pb = os.path.join(a, n + '.ppm'), os.path.join(b, n + '.ppm')
    if not os.path.exists(pb):
        print("%-24s MISSING in %s" % (n, b)); fail = True; continue
    w, h, g = load(pa); _, _, f = load(pb)
    d = sum(1 for i in range(0, len(g), 3) if g[i:i+3] != f[i:i+3])
    if d == 0:
        print("%-24s IDENTICAL" % n); continue
    # is it purely the 1-pixel registration fix?
    sh = sum(1 for y in range(h) for x in range(w-1)
             if not HUD(x, y) and f[(y*w+x)*3:(y*w+x)*3+3] != g[(y*w+x+1)*3:(y*w+x+1)*3+3])
    if sh == 0:
        print("%-24s %d px differ -> exactly a 1-pixel registration fix" % (n, d))
    else:
        print("%-24s %d px differ, %d residual  <-- REAL DIFFERENCE" % (n, d, sh)); fail = True
sys.exit(1 if fail else 0)
