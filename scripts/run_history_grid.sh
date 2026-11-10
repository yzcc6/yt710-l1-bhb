#!/bin/bash
# run_history_grid.sh —— 16 点链长扫描（每点约 2 分钟）
set -u
cd "$(dirname "$0")/.."
HS="${HS:-32 48 64 96 128 160 192 224 256 288 304 320 336 352 384 512}"
OUT="${OUT:-data/sweep_raw.csv}"
echo "H,main_mean,main_max,main_ge10" > "$OUT"

for H in $HS; do
  taskset -c 3 ./calib --history "$H" --in-place 1 --hit-num 100 --rounds 300 --iters 100 \
      --out "/tmp/h${H}.csv" 2>>/tmp/calib_ruler.log
  awk -F, -v h="$H" 'NR>1&&$4=="MAIN"{n++;s+=$6;if($6>m)m=$6;if($6>=10)g++}
       END{if(n>0) printf "%d,%.4f,%d,%d\n", h, s/n, m, g}' /tmp/h${H}.csv >> "$OUT"
  echo "=== H=$H done ==="
done
echo "DONE -> $OUT"
