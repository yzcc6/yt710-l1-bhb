#!/bin/bash
# run_fg.sh (v3) —— 前台运行，全程打印进度，约 25 分钟
#
# 用法：
#   pkill -f run_all.sh          # 先停掉后台的旧任务
#   chmod +x run_fg.sh
#   ./run_fg.sh                  # 前台跑，屏幕上能一直看到进度
#
# 产物：report_data.md / sweep.csv / trainn.csv / r_*.csv

set -u
CAL=./bhb_final
OUT=report_data.md
CORE=3
GATE="--min-self 5"

: > "$OUT"
: > sweep.csv
: > trainn.csv

T0=$(date +%s)
el() { echo $(( $(date +%s) - T0 )); }

sec() { { echo ""; echo "### $*"; echo ""; } >> "$OUT"; }
say() { printf "[%3ds] %s\n" "$(el)" "$*"; }

mstats() {
  awk -F, -v it="$2" 'NR>1&&$4=="MAIN"{n++;s+=$6;if($6>mx)mx=$6;if($6>=10)g++;if($6>=51)h++}
    END{if(n) printf "%.2f|%.0f|%.1f%%|%d", 100*s/n/it, mx, 100*g/n, h+0; else printf "NA"}' "$1"
}
cstats() {
  awk -F, -v it="$2" 'NR>1&&$4=="CTRL"{n++;s+=$6;if($6>mx)mx=$6;if($6>=10)g++}
    END{if(n) printf "%.3f|%.0f|%d", 100*s/n/it, mx, g+0; else printf "NA"}' "$1"
}

run_pt() {  # H TN HN RD IT SD TAG [extra]
  local H=$1 TN=$2 HN=$3 RD=$4 IT=$5 SD=$6 TAG=$7; shift 7
  taskset -c $CORE $CAL --history "$H" --train-n "$TN" --hit-num "$HN" --rounds "$RD" \
      --iters "$IT" --seed "$SD" $GATE "$@" --out "r_${TAG}.csv" 2> "r_${TAG}.err"
  [ -s "r_${TAG}.csv" ]
}

# ============================== A ==============================
say "▶ A 冒烟与闸门（约 30 秒）"
sec "A · 冒烟与闸门（H=256）"
if run_pt 256 1 5 20 100 1 smoke; then
  grep -E "^\[(ruler|POS|SELF|result)\]" r_smoke.err >> "$OUT"
  say "✔ A 完成：$(grep -o '\[POS\].*' r_smoke.err | head -1)"
else
  echo "A GATE_FAIL" >> "$OUT"; say "✘ A 闸门失败"
fi

# ============================== B ==============================
say "▶ B 主结果 20 万轮（约 3~4 分钟）"
sec "B · 主结果（H=256，train_n=1，20 万轮）"
if run_pt 256 1 200 1000 100 42 main; then
  grep "\[result\]" r_main.err >> "$OUT"
  { echo ""; echo "| 指标 | MAIN | CTRL |"; echo "|---|---|---|";
    echo "| 均值%\\|最大\\|≥10占比\\|≥51轮数 || $(mstats r_main.csv 100) \\| $(cstats r_main.csv 100) |"; } >> "$OUT"
  L=$(awk -F, 'NR>1&&$4=="MAIN"{n++;s+=$6} END{printf "%.2f", 100*s/n/100}' r_main.csv)
  C=$(awk -F, 'NR>1&&$4=="CTRL"{n++;s+=$6} END{printf "%.3f", 100*s/n/100}' r_main.csv)
  say "✔ B 完成：MAIN=$L%  CTRL=$C%"
else
  echo "B GATE_FAIL" >> "$OUT"; say "✘ B 闸门失败"
fi

# ============================== C ==============================
say "▶ C 链长扫描 10 点（每点约 40 秒，共约 7 分钟）"
sec "C · HISTORY_SIZE 扫描（train_n=1，100 链 × 200 轮）"
{ echo ""; echo "| H | MAIN 均值% | MAIN 最大 | MAIN ≥10 | CTRL 均值% | CTRL ≥10 |"
  echo "|---|---|---|---|---|---|"; } >> "$OUT"
echo "H,main_pct,ctrl_pct" > sweep.csv
for H in 32 64 128 192 224 256 288 320 384 512; do
  printf "[%3ds]   C: H=%-4s 跑..." "$(el)" "$H"
  if run_pt $H 1 100 200 100 42 h$H; then
    M=$(mstats r_h$H.csv 100); C=$(cstats r_h$H.csv 100)
    echo "�� → MAIN=$(echo "$M" | cut -d'|' -f1)% (最大 $(echo "$M" | cut -d'|' -f2), ≥10 $(echo "$M" | cut -d'|' -f3))  CTRL=$(echo "$C" | cut -d'|' -f1)%"
    echo "| $H | $(echo "$M" | cut -d'|' -f1) | $(echo "$M" | cut -d'|' -f2) | $(echo "$M" | cut -d'|' -f3) | $(echo "$C" | cut -d'|' -f1) | $(echo "$C" | cut -d'|' -f3) |" >> "$OUT"
    echo "$H,$(echo "$M" | cut -d'|' -f1),$(echo "$C" | cut -d'|' -f1)" >> sweep.csv
  else
    echo "✘ GATE_FAIL"; echo "| $H | GATE_FAIL | - | - | - | - |" >> "$OUT"
  fi
done

# ============================== D ==============================
say "▶ D 重复性（256/288 各 2 次，约 3 分钟）"
sec "D · 重复性（H=256 / 288，各 2 次独立运行）"
{ echo ""; echo "| H | run1 | run2 | 均值 | 差值 |"; echo "|---|---|---|---|---|"; } >> "$OUT"
for H in 256 288; do
  a=""; b=""
  printf "[%3ds]   D: H=%-4s run1..." "$(el)" "$H"
  if run_pt $H 1 100 200 100 41 rep${H}_1; then a=$(awk -F, 'NR>1&&$4=="MAIN"{n++;s+=$6} END{printf "%.2f",100*s/n/100}' r_rep${H}_1.csv); printf " %s%%" "$a"; else a="FAIL"; printf " FAIL"; fi
  printf "  run2..."
  if run_pt $H 1 100 200 100 42 rep${H}_2; then b=$(awk -F, 'NR>1&&$4=="MAIN"{n++;s+=$6} END{printf "%.2f",100*s/n/100}' r_rep${H}_2.csv); printf " %s%%\n" "$b"; else b="FAIL"; printf " FAIL\n"; fi
  m=$(echo "$a $b" | awk '{if($1=="FAIL"||$2=="FAIL")print "NA";else printf "%.2f",($1+$2)/2}')
  d=$(echo "$a $b" | awk '{if($1=="FAIL"||$2=="FAIL")print "NA";else printf "%.2f",($1>$2?$1-$2:$2-$1)}')
  echo "| $H | $a | $b | $m | $d |" >> "$OUT"
done

# ============================== E ==============================
say "▶ E 异地对照（约 1.5 分钟）"
sec "E · 异地对照（--in-place 0）"
{ echo ""; echo "| H | 测量次数 | MAIN 均值% | MAIN 最大 | CTRL 均值% |"; echo "|---|---|---|---|---|"; } >> "$OUT"
for H in 64 256; do
  printf "[%3ds]   E: 异地 H=%-4s 跑..." "$(el)" "$H"
  if run_pt $H 1 100 200 100 42 out$H --in-place 0; then
    M=$(mstats r_out$H.csv 100); C=$(cstats r_out$H.csv 100)
    echo "→ MAIN=$(echo "$M"|cut -d'|' -f1)% (最大 $(echo "$M"|cut -d'|' -f2))"
    echo "| $H | 4,000,000 | $(echo "$M"|cut -d'|' -f1) | $(echo "$M"|cut -d'|' -f2) | $(echo "$C"|cut -d'|' -f1) |" >> "$OUT"
  else
    echo "✘ GATE_FAIL"; echo "| $H | 4,000,000 | GATE_FAIL | - | - |" >> "$OUT"
  fi
done

# ============================== F ==============================
say "▶ F tail-match 5 档（约 3.5 分钟）"
sec "F · 尾部匹配条数（H=256）"
{ echo ""; echo "| tail_match | MAIN 均值% | MAIN 最大 | CTRL 均值% |"; echo "|---|---|---|---|"; } >> "$OUT"
for N in 1 8 16 32 64; do
  printf "[%3ds]   F: tail_match=%-3s 跑..." "$(el)" "$N"
  if run_pt 256 1 100 200 100 42 tm$N --tail-match $N; then
    M=$(mstats r_tm$N.csv 100); C=$(cstats r_tm$N.csv 100)
    echo "→ MAIN=$(echo "$M"|cut -d'|' -f1)%"
    echo "| $N | $(echo "$M"|cut -d'|' -f1) | $(echo "$M"|cut -d'|' -f2) | $(echo "$C"|cut -d'|' -f1) |" >> "$OUT"
  else
    echo "✘ GATE_FAIL"; echo "| $N | GATE_FAIL | - | - |" >> "$OUT"
  fi
done

# ============================== G ==============================
say "▶ G 训练强度 1/8/32/128（约 4 分钟）"
sec "G · 训练强度（H=256）"
{ echo ""; echo "| train_n | 规模 | MAIN 均值% | MAIN 最大 | CTRL 均值% |"; echo "|---|---|---|---|---|"; } >> "$OUT"
echo "train_n,main_pct" > trainn.csv
for N in 1 8 32; do
  printf "[%3ds]   G: train_n=%-4s 跑..." "$(el)" "$N"
  if run_pt 256 $N 50 100 50 42 tn$N; then
    M=$(mstats r_tn$N.csv 50); C=$(cstats r_tn$N.csv 50)
    echo "→ MAIN=$(echo "$M"|cut -d'|' -f1)%"
    echo "| $N | 500,000 次 | $(echo "$M"|cut -d'|' -f1) | $(echo "$M"|cut -d'|' -f2) | $(echo "$C"|cut -d'|' -f1) |" >> "$OUT"
    echo "$N,$(echo "$M"|cut -d'|' -f1)" >> trainn.csv
  else
    echo "✘ GATE_FAIL"; echo "| $N | 500,000 次 | GATE_FAIL | - | - |" >> "$OUT"
  fi
done
printf "[%3ds]   G: train_n=128  跑（这个较慢，约 2 分钟）..." "$(el)"
if run_pt 256 128 50 60 30 42 tn128; then
  M=$(mstats r_tn128.csv 30); C=$(cstats r_tn128.csv 30)
  echo "→ MAIN=$(echo "$M"|cut -d'|' -f1)%"
  echo "| 128 | 180,000 次 | $(echo "$M"|cut -d'|' -f1) | $(echo "$M"|cut -d'|' -f2) | $(echo "$C"|cut -d'|' -f1) |" >> "$OUT"
  echo "128,$(echo "$M"|cut -d'|' -f1)" >> trainn.csv
else
  echo "✘ GATE_FAIL"; echo "| 128 | 180,000 次 | GATE_FAIL | - | - |" >> "$OUT"
fi

# ============================== H ==============================
say "▶ H 与 main.c 口径对跑（train_n=128，5 档，约 4 分钟）"
sec "H · 与 main.c 口径对跑（train_n=128）"
{ echo ""; echo "| H | run1% | run2% | 均值% |"; echo "|---|---|---|---|"; } >> "$OUT"
for H in 192 224 256 288 304; do
  a=""; b=""
  printf "[%3ds]   H: train128 H=%-4s ..." "$(el)" "$H"
  if run_pt $H 128 50 60 30 41 x${H}_1; then a=$(awk -F, 'NR>1&&$4=="MAIN"{n++;s+=$6} END{printf "%.2f",100*s/n/30}' r_x${H}_1.csv); printf " %s%%" "$a"; else a="FAIL"; printf " FAIL"; fi
  printf " /"
  if run_pt $H 128 50 60 30 42 x${H}_2; then b=$(awk -F, 'NR>1&&$4=="MAIN"{n++;s+=$6} END{printf "%.2f",100*s/n/30}' r_x${H}_2.csv); printf " %s%%\n" "$b"; else b="FAIL"; printf " FAIL\n"; fi
  m=$(echo "$a $b" | awk '{if($1=="FAIL"||$2=="FAIL")print "NA";else printf "%.2f",($1+$2)/2}')
  echo "| $H | $a | $b | $m |" >> "$OUT"
done

# ============================== 结束 ==============================
sec "DONE"
echo "全部数据已写入 $OUT（总耗时 $(el) 秒）" >> "$OUT"

echo
echo "=============================================="
echo "  ✅ ALL DONE   总耗时 $(el) 秒（约 $(( $(el) / 60 )) 分钟）"
echo "  结果文件: $OUT"
echo "=============================================="
echo
cat "$OUT"
