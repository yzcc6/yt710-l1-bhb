#!/bin/bash
# run_controls.sh —— 三条对照：异地 / tail-match / CTRL 提取
set -u
cd "$(dirname "$0")/.."
OUT="${OUT:-data/controls_raw.csv}"
echo "config,H,N,tail_match,main_mean,main_max,main_ge10" > "$OUT"

summ() {  # $1=file $2=config $3=H $4=N $5=tail
  awk -F, -v c="$2" -v h="$3" -v n="$4" -v t="$5" \
    'NR>1&&$4=="MAIN"{k++;s+=$6;if($6>m)m=$6;if($6>=10)g++}
     END{if(k>0) printf "%s,%d,%d,%d,%.4f,%d,%d\n", c, h, n, t, s/k, m, g}' "$1" >> "$OUT"
}

echo "--- ① 异地（in-place 0），H=64 与 H=256 ---"
for H in 64 256; do
  taskset -c 3 ./calib --history $H --in-place 0 --hit-num 100 --rounds 300 --iters 100 --out /tmp/out_$H.csv
  summ /tmp/out_$H.csv outplace $H 1 0
done

echo "--- ② tail-match 1/8/16/32/64（H=256）---"
for N in 1 8 16 32 64; do
  taskset -c 3 ./calib --history 256 --tail-match $N --hit-num 100 --rounds 300 --iters 100 --out /tmp/tm_$N.csv
  summ /tmp/tm_$N.csv tailmatch 256 1 $N
done

echo "--- ③ CTRL 提取（各档）---"
for H in 256 288 304 320 336; do
  f="/tmp/h${H}.csv"; [ -f "$f" ] || f="/tmp/r_${H}_1.csv"
  [ -f "$f" ] || { echo "skip H=$H (无数据文件)"; continue; }
  awk -F, -v h="$H" 'NR>1&&$4=="CTRL"{n++;s+=$6;if($6>=10)g++}
       END{if(n>0) printf "ctrl,%d,1,0,,,%d\n", h, g}' "$f" >> "$OUT"
done

echo "DONE -> $OUT"
