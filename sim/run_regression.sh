#!/usr/bin/env bash
# DEPTH regression kit.
#   ./run_regression.sh            -> render frames + logic log from src/
#   ./run_regression.sh <olddir>   -> also diff against another checkout
# Needs: verilator, g++, python3
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
OUT="$HERE/out"; rm -rf "$OUT"; mkdir -p "$OUT/frames" "$OUT/flat" "$OUT/logic"

build_and_run () {          # <srcdir> <memdir> <outdir> <harness> <bin> [extra verilator args]
    local src="$1" mem="$2" dir="$3" harness="$4" bin="$5"; shift 5
    mkdir -p "$dir"; cp "$mem"/*.mem "$dir"/
    ( cd "$dir" && verilator --cc --exe --build -j "$(nproc)" -O2 -CFLAGS "-O2" \
        --public-flat-rw --Wno-fatal -Wno-lint -I"$src" --top-module top_depth "$@" \
        --Mdir obj -o "$bin" "$src"/*.v "$harness" >/dev/null && ./obj/"$bin" )
}

echo "== rendering frames (DEPTH_SHADING=1, as shipped) =="
build_and_run "$ROOT/src" "$ROOT/mem" "$OUT/frames" "$HERE/harness.cpp" Vfr

echo "== rendering frames (DEPTH_SHADING=0, for pixel regression) =="
build_and_run "$ROOT/src" "$ROOT/mem" "$OUT/flat" "$HERE/harness.cpp" Vfl -GDEPTH_SHADING=0

echo "== game-logic log =="
build_and_run "$ROOT/src" "$ROOT/mem" "$OUT/logic" "$HERE/logharness.cpp" Vlog

echo "== sonar vs independent reference model =="
python3 "$HERE/sonar_model.py" "$OUT/logic/out_logic.txt"

if [ $# -ge 1 ]; then
    OLD="$1"
    echo "== building reference from $OLD =="
    build_and_run "$OLD/src" "$OLD/mem" "$OUT/ref" "$HERE/harness.cpp" Vref
    build_and_run "$OLD/src" "$OLD/mem" "$OUT/reflog" "$HERE/logharness.cpp" Vreflog
    echo "== pixel diff (reference vs DEPTH_SHADING=0) =="
    python3 "$HERE/compare_frames.py" "$OUT/ref" "$OUT/flat"
    echo "== logic diff =="
    diff "$OUT/reflog/out_logic.txt" "$OUT/logic/out_logic.txt" >/dev/null \
        && echo "logic: IDENTICAL" || echo "logic: differs (expected: sonar distances only)"
fi
echo "done -> $OUT"
