#!/bin/bash
# run_all.sh (v2) —— 用 bhb_final（合并版）重跑 L1-1 报告所需的全部数据
#
# v2 修正：
#   1. 所有运行统一加 --min-self 5
#      （原 min_self=20 会在短链 H=32/48/64 上误拦：链越短自撞率越低）
#   2. 每次运行后检查 CSV 是否生成；没生成则在该行写 GATE_FAIL 而不是让 awk 报错
#   3. 闸门的 stderr 写入 r_*.err，便于事后查原因
#
# 用法：
#   chmod +x run_all.sh
#   nohup ./run_all.sh > run_all.log 2>&1 &
#   tail -f run_all.log
#
# 产物：report_data.md / sweep.csv / trainn.csv / r_*.csv

set -u
CAL=./bhb_final
OUT=report_data.md
CORE=3
GATE="--min-self 5"          # 短链也能过闸，但仍能拦住"完全抓不到瞬态"

: > "$OUT"
: > sweep.csv
: > trainn.csv

log() { echo "=== $* ==="; }
sec() { { echo ""; echo "### $*"; echo ""; } >> "$OUT"; }

# 运行一个点：run_pt <H> <train_n> <hit_num> <rounds> <iters> <seed> <tag> [extra...]
run_pt() {
  local H=$1 TN=$2 HN=$3 RD=$4 IT=$5 SD=$6 TAG=$7; shift 7
  taskset -c $CORE $CAL --history "$H" --train-n "$TN" --hit-num "$HN" --rounds "$RD" \
      --iters "$IT" --seed "$SD" $GATE "$@" --out "r_${TAG}.csv" 2> "r_${TAG}.err"
  if [ ! -s "r_${TAG}.csv" ]; then
    echo "GATE_FAIL($?)" >&2
    return 1
  fi
  return 0
}

# MAIN 统计：mean% | max | ge10% | ge51
mstats() {
  awk -F, -v it="$2" 'NR>1&&$4=="MAIN"{n++;s+=$6;if($6>mx)mx=$6;if($6>=10)g++;if($6>=51)h++}
    END{if(n) printf "%.2f | %.0f | %.1f%% | %d", 100*s/n/it, mx, 100*g/n, h+0; else printf "NA"}' "$1"
}
# CTRL 统计：mean% | max | ge10
cstats() {
  awk -F, -v it="$2" 'NR>1&&$4=="CTRL"{n++;s+=$6;if($6>mx)mx=$6;if($6>=10)g++}
    END{if(n) printf "%.3f | %.0f | %d", 100*s/n/it, mx, g+0; else printf "NA"}' "$1"
}

# ---------------------------------------------------------------- A 冒烟
log "A 冒烟与闸门"
sec "A · 冒烟与闸门（H=256）"
run_pt 256 1 5 20 100 1 smoke || true
grep -E "^\[(ruler|POS|SELF|result)\]" r_smoke.err >> "$OUT" 2>/dev/null

# ---------------------------------------------------------------- B 主结果
log "B 主结果 20 万轮"
sec "B · 主结果（H=256，train_n=1，20 万轮）"
if run_pt 256 1 200 1000 100 42 main; then
  grep "\[result\]" r_main.err >> "$OUT"
  {
    echo ""
    echo "| 指标 | MAIN | CTRL |"
    echo "|---|---|---|"
    echo "| 均值% \| 最大 \| ≥10占比 \| ≥51轮数 || $(mstats r_main.csv 100) \| $(cstats r_main.csv 100) |"
  } >> "$OUT"
else
  echo "主结果 GATE_FAIL" >> "$OUT"
fi

# ---------------------------------------------------------------- C 链长扫描
log "C 链长扫描（16 点）"
sec "C · HISTORY_SIZE 扫描（train_n=1，每点 100 链 × 300 轮）"
{
  echo ""
  echo "| H | MAIN 均值% | MAIN 最大 | MAIN ≥10 | MAIN ≥51 | CTRL 均值% | CTRL 最大 | CTRL ≥10 |"
  echo "|---|---|---|---|---|---|---|---|"
} >> "$OUT"
echo "H,main_pct,ctrl_pct" > sweep.csv
for H in 32 48 64 96 128 160 192 224 256 288 304 320 336 352 384 512; do
  if run_pt $H 1 100 300 100 42 h$H; then
    M=$(mstats r_h$H.csv 100); C=$(cstats r_h$H.csv 100)
    echo "| $H | $M | $C |" >> "$OUT"
    echo "$H,$(echo "$M" | cut -d'|' -f1 | tr -d ' '),$(echo "$C" | cut -d'|' -f1 | tr -d ' ')" >> sweep.csv
    log "H=$H -> $M"
  else
    echo "| $H | GATE_FAIL | - | - | - | - | - | - |" >> "$OUT"
    log "H=$H -> GATE_FAIL"
  fi
done

# ---------------------------------------------------------------- D 重复性
log "D 重复性（256 / 288 各 3 次）"
sec "D · 重复性（H=256 / 288，各 3 次独立运行）"
{
  echo ""
  echo "| H | run1 | run2 | run3 | 均值 | 标准差 |"
  echo "|---|---|---|---|---|---|"
} >> "$OUT"
for H in 256 288; do
  v1=""; v2=""; v3=""
  for i in 1 2 3; do
    if run_pt $H 1 100 300 100 $((40+i)) rep${H}_$i; then
      x=$(awk -F, 'NR>1&&$4=="MAIN"{n++;s+=$6} END{printf "%.2f", 100*s/n/100}' r_rep${H}_$i.csv)
    else
      x="FAIL"
    fi
    eval "v$i=$x"
  done
  st=$(echo "$v1 $v2 $v3" | awk '{if($1=="FAIL"||$2=="FAIL"||$3=="FAIL"){print "NA|NA";exit}
        m=($1+$2+$3)/3; d1=$1-m;d2=$2-m;d3=$3-m;
        printf "%.2f|%.2f", m, sqrt((d1*d1+d2*d2+d3*d3)/2)}')
  echo "| $H | $v1 | $v2 | $v3 | $(echo $st | cut -d'|' -f1) | $(echo $st | cut -d'|' -f2) |" >> "$OUT"
  log "H=$H 重复 $v1 $v2 $v3"
done

# ---------------------------------------------------------------- E 异地
log "E 异地对照"
sec "E · 异地对照（--in-place 0，最后一条地址也不复用）"
{
  echo ""
  echo "| H | 测量次数 | MAIN 均值% | MAIN 最大 | CTRL 均值% |"
  echo "|---|---|---|---|---|"
} >> "$OUT"
for H in 64 256; do
  if run_pt $H 1 100 300 100 42 out$H --in-place 0; then
    M=$(mstats r_out$H.csv 100); C=$(cstats r_out$H.csv 100)
    echo "| $H | 6,000,000 | $M | $C |" >> "$OUT"
    log "异地 H=$H -> $M"
  else
    echo "| $H | 6,000,000 | GATE_FAIL | - | - |" >> "$OUT"
    log "异地 H=$H -> GATE_FAIL"
  fi
done

# ---------------------------------------------------------------- F tail-match
log "F tail-match"
sec "F · 尾部匹配条数（H=256，--tail-match 1/8/16/32/64）"
{
  echo ""
  echo "| tail_match | MAIN 均值% | MAIN 最大 | CTRL 均值% |"
  echo "|---|---|---|---|"
} >> "$OUT"
for N in 1 8 16 32 64; do
  if run_pt 256 1 100 300 100 42 tm$N --tail-match $N; then
    echo "| $N | $(mstats r_tm$N.csv 100) | $(cstats r_tm$N.csv 100) |" >> "$OUT"
    log "tail_match=$N -> $(mstats r_tm$N.csv 100)"
  else
    echo "| $N | GATE_FAIL | - | - |" >> "$OUT"
  fi
done

# ---------------------------------------------------------------- G 训练强度
log "G 训练强度（1/8/32 全量，128 轻量）"
sec "G · 训练强度（H=256）"
{
  echo ""
  echo "| train_n | 规模 | MAIN 均值% | MAIN 最大 | CTRL 均值% |"
  echo "|---|---|---|---|---|"
} >> "$OUT"
echo "train_n,main_pct" > trainn.csv
for N in 1 8 32; do
  if run_pt 256 $N 100 300 100 42 tn$N; then
    M=$(mstats r_tn$N.csv 100); C=$(cstats r_tn$N.csv 100)
    echo "| $N | 6,000,000 次 | $M | $C |" >> "$OUT"
    echo "$N,$(echo "$M" | cut -d'|' -f1 | tr -d ' ')" >> trainn.csv
    log "train_n=$N -> $M"
  else
    echo "| $N | 6,000,000 次 | GATE_FAIL | - | - |" >> "$OUT"
  fi
done
if run_pt 256 128 50 60 30 42 tn128; then
  M=$(mstats r_tn128.csv 30); C=$(cstats r_tn128.csv 30)
  echo "| 128 | 180,000 次（轻量） | $M | $C |" >> "$OUT"
  echo "128,$(echo "$M" | cut -d'|' -f1 | tr -d ' ')" >> trainn.csv
  log "train_n=128 -> $M"
else
  echo "| 128 | 180,000 次（轻量） | GATE_FAIL | - | - |" >> "$OUT"
fi

# ---------------------------------------------------------------- H 交叉验证
log "H 与 main.c 口径对跑（train_n=128）"
sec "H · 与 main.c 口径对跑（train_n=128，轻量网格）"
{
  echo ""
  echo "| H | run1% | run2% | 均值% |"
  echo "|---|---|---|---|"
} >> "$OUT"
for H in 192 224 256 288 304; do
  v1=""; v2=""
  for i in 1 2; do
    if run_pt $H 128 50 60 30 $((40+i)) x${H}_$i; then
      x=$(awk -F, 'NR>1&&$4=="MAIN"{n++;s+=$6} END{printf "%.2f", 100*s/n/30}' r_x${H}_$i.csv)
    else
      x="FAIL"
    fi
    eval "v$i=$x"
  done
  m=$(echo "$v1 $v2" | awk '{if($1=="FAIL"||$2=="FAIL"){print "NA"}else{printf "%.2f",($1+$2)/2}}')
  echo "| $H | $v1 | $v2 | $m |" >> "$OUT"
  log "H=$H -> $v1 $v2 (均值 $m)"
done

# ---------------------------------------------------------------- 完成
sec "DONE"
echo "全部数据已写入 $OUT" >> "$OUT"
log "ALL DONE -> $OUT"
