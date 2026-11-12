#!/usr/bin/env python3
"""make_figs.py —— 用 run_all.sh 的产物画 3 张图

用法：
    python3 make_figs.py

依赖：matplotlib（没装就跳过，用表格代替）
产物：fig_sweep.png / fig_trainn.png / fig_repeat.png
"""
import csv
import os
import sys

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    print("没有 matplotlib，跳过画图。先装：sudo apt install -y python3-matplotlib")
    sys.exit(0)


def load(path):
    xs, ys = [], []
    if not os.path.exists(path):
        return xs, ys
    with open(path) as f:
        for r in csv.DictReader(f):
            try:
                xs.append(int(r["H"] if "H" in r else r["train_n"]))
                ys.append(float(r["main_pct"]))
            except (KeyError, ValueError):
                pass
    return xs, ys


# ---- 图 1：链长扫描 ----
xs, ys_m = load("sweep.csv")
_, ys_c = [], []
with open("sweep.csv") as f:
    rd = csv.DictReader(f)
    for r in rd:
        try:
            ys_c.append(float(r["ctrl_pct"]))
        except (KeyError, ValueError):
            ys_c.append(0.0)

if xs:
    plt.figure(figsize=(8, 4.2))
    plt.plot(xs, ys_m, "o-", label="MAIN (train to attack)")
    if len(ys_c) == len(xs):
        plt.plot(xs, ys_c, "s-", label="CTRL (train to safe)")
    plt.axvline(256, color="gray", ls=":", lw=1)
    plt.xlabel("HISTORY_SIZE")
    plt.ylabel("hit rate (%)")
    plt.title("L1-1: HISTORY_SIZE sweep (bhb_final, train_n=1)")
    plt.legend()
    plt.grid(alpha=0.3)
    plt.tight_layout()
    plt.savefig("fig_sweep.png", dpi=140)
    print("wrote fig_sweep.png")

# ---- 图 2：训练强度 ----
xs2, ys2 = load("trainn.csv")
if xs2:
    plt.figure(figsize=(6, 4))
    plt.plot(xs2, ys2, "o-", color="#c0392b")
    for x, y in zip(xs2, ys2):
        plt.annotate(f"{y:.1f}%", (x, y), textcoords="offset points", xytext=(0, 8), ha="center")
    plt.xlabel("--train-n (training passes per measurement)")
    plt.ylabel("hit rate (%)")
    plt.title("L1-1: sensitivity to training strength (H=256)")
    plt.grid(alpha=0.3)
    plt.tight_layout()
    plt.savefig("fig_trainn.png", dpi=140)
    print("wrote fig_trainn.png")

# ---- 图 3：THR 直方图（若存在 hist 数据）----
try:
    import subprocess
    if os.path.exists("r_hist.csv"):
        buckets = {}
        with open("r_hist.csv") as f:
            for r in csv.DictReader(f):
                if r.get("mode") != "MAIN":
                    continue
                try:
                    buckets[int(r["dt"])] = buckets.get(int(r["dt"]), 0) + int(r["count"])
                except (KeyError, ValueError):
                    pass
        if buckets:
            ks = sorted(buckets)[:16]
            plt.figure(figsize=(7, 4))
            plt.bar(ks, [buckets[k] for k in ks], color="#2e74b5")
            plt.axvline(3.5, color="green", ls="--", lw=1.2, label="THR=4")
            plt.xlabel("load_time (tick, 20 ns)")
            plt.ylabel("count")
            plt.title("L1-1: dt histogram (MAIN), THR sits in the gap")
            plt.legend()
            plt.grid(alpha=0.3, axis="y")
            plt.tight_layout()
            plt.savefig("fig_thr.png", dpi=140)
            print("wrote fig_thr.png")
except Exception as e:      # noqa: BLE001
    print("THR 图跳过：", e)
