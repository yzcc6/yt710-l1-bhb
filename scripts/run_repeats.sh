#!/bin/bash
# run_repeats.sh —— 重复性测量（用于确定运行间标准差）
set -u
cd "$(dirname "$0")/.."
OUT="${OUT:-data/repeats_raw.csv}"
echo "H,run,mean" > "$OUT"

run_n() {   # $1=H  $2=重复次数
  for i in $(seq 1 "$2"); do
    taskset -c 3 ./calib --history "$1" --in-place 1 --hit-num 100 --rounds 300 --iters 100 \
        --out "/tmp/r_${1}_${i}.csv" 2>/dev/null
    awk -F, -v h="$1" -v r="$i" 'NR>1&&$4=="MAIN"{n++;s+=$6}
         END{if(n>0) printf "%d,%d,%.3f\n", h, r, s/n}' "/tmp/r_${1}_${i}.csv" >> "$OUT"
  done
  echo "=== H=$1 done ==="
}

run_n 256 5
run_n 288 6
run_n 304 3
run_n 320 3
run_n 336 3
echo "DONE -> $OUT"
