#!/bin/bash
# run_repro.sh —— 主实验：复现 L1-1 的 17.99%
# 规模：200 训练链 x 1000 轮 x 2 模式 x 100 次 = 4000 万次测量（约 15 分钟）
set -u
cd "$(dirname "$0")/.."
H="${H:-256}"
OUT="${OUT:-final_256.csv}"

echo "=== 主实验：H=$H in-place ==="
taskset -c 3 ./calib --history "$H" --in-place 1 \
    --hit-num 200 --rounds 1000 --iters 100 --out "$OUT"

echo
echo "=== 统计 ==="
awk -F, 'NR>1&&$4=="MAIN"{n++;s+=$6;if($6>m)m=$6;if($6>=10)g++;if($6>=51)h++}
     END{printf "MAIN  n=%d 均值=%.4f 最大=%d >=10:%d(%.1f%%) >=51:%d\n",n,s/n,m,g,100*g/n,h}' "$OUT"
awk -F, 'NR>1&&$4=="CTRL"{n++;s+=$6;if($6>m)m=$6;if($6>=10)g++}
     END{printf "CTRL  n=%d 均值=%.4f 最大=%d >=10:%d\n",n,s/n,m,g}' "$OUT"

echo
echo "期望（H=256）："
echo "  MAIN  n=200000 均值≈17.99 最大≈59 >=10≈160021(80%)"
echo "  CTRL  n=200000 均值≈0.06 最大≈3  >=10:0"
