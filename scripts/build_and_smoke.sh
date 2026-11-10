#!/bin/bash
# build_and_smoke.sh —— 编译 + ruler 自检 + 冒烟
set -eu
cd "$(dirname "$0")/.."
UP="${UP:-../../../}"

echo "=== ① 环境自检 ==="
uname -m
nproc
grep -A3 "defined YITIAN_710" "$UP/common/targets.h" | grep THR || {
    echo "!! targets.h 缺 YITIAN_710 块"; exit 1; }
grep -q cntvct "$UP/common/helper.h" && echo "helper.h: cntvct OK" || {
    echo "!! helper.h 未改计时源（见 patches/PATCH.md 补丁1）"; exit 1; }

echo "=== ② 编译 ==="
gcc -c src/snippet.S -o snippet.o -I"$UP/common" -DYITIAN_710
gcc src/calib.c -o calib snippet.o -pie -O1 -I"$UP/common" -DYITIAN_710
echo "calib built"

echo "=== ③ 冒烟 H=256（期望 15~21）==="
taskset -c 3 ./calib --history 256 --in-place 1 --hit-num 100 --rounds 300 --iters 100 --out /tmp/smoke256.csv
v=$(awk -F, 'NR>1&&$4=="MAIN"{n++;s+=$6} END{printf "%.2f", s/n}' /tmp/smoke256.csv)
echo "smoke H=256 mean = $v"
awk -v v="$v" 'BEGIN{
    if (v>=15 && v<=21) print "OK 可继续"
    else if (v>=10 && v<15) print "偏低：查 THR / 干扰 / BHB 被占"
    else print "不在范围，先别跑网格"}'
