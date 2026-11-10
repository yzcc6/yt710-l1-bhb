#!/usr/bin/env python3
"""analyze_sweep.py —— calib 聚合 CSV 的统计

用法:
    python3 analyze_sweep.py h288.csv              # 单文件：分布统计
    python3 analyze_sweep.py h256.csv h288.csv     # 两文件：Welch t 检验

输入格式（calib --out 的输出）:
    hit_id,round,order,mode,iters,hits,min_dt,max_dt
"""
import csv
import math
import sys
from statistics import mean, stdev


def load(path):
    """返回 {mode: [hits, ...]}"""
    by = {"MAIN": [], "CTRL": []}
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            m = r.get("mode")
            if m in by:
                try:
                    by[m].append(int(r["hits"]))
                except (KeyError, ValueError):
                    pass
    return by


def describe(xs):
    if not xs:
        return None
    xs_sorted = sorted(xs)
    n = len(xs)
    return {
        "n": n,
        "mean": mean(xs),
        "sd": stdev(xs) if n > 1 else float("nan"),
        "median": xs_sorted[n // 2],
        "max": max(xs),
        "ge10": sum(1 for v in xs if v >= 10),
        "ge30": sum(1 for v in xs if v >= 30),
    }


def welch(a, b):
    """Welch t 检验，返回 (t, df, p)"""
    na, nb = len(a), len(b)
    if na < 2 or nb < 2:
        return float("nan"), float("nan"), float("nan")
    va, vb = stdev(a) ** 2, stdev(b) ** 2
    se = math.sqrt(va / na + vb / nb)
    if se == 0:
        return float("nan"), float("nan"), float("nan")
    t = (mean(a) - mean(b)) / se
    df = (va / na + vb / nb) ** 2 / ((va / na) ** 2 / (na - 1) + (vb / nb) ** 2 / (nb - 1))
    return t, df, 2 * (1 - t_cdf(abs(t), df))


# ---- t 分布 CDF（用不完全 beta 实现，避免依赖 scipy）----

def _betacf(a, b, x, itmax=200, eps=3e-12):
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    d = 1.0 / (d if abs(d) > 1e-30 else 1e-30)
    h = d
    for m in range(1, itmax + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > 1e-30 else 1e-30)
        c = 1.0 + aa / c
        c = c if abs(c) > 1e-30 else 1e-30
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > 1e-30 else 1e-30)
        c = 1.0 + aa / c
        c = c if abs(c) > 1e-30 else 1e-30
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < eps:
            break
    return h


def _betai(a, b, x):
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    lbeta = math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
    front = math.exp(lbeta + a * math.log(x) + b * math.log(1 - x))
    if x < (a + 1) / (a + b + 2):
        return front * _betacf(a, b, x) / a
    return 1 - front * _betacf(b, a, 1 - x) / b


def t_cdf(t, df):
    x = df / (df + t * t)
    p = 0.5 * _betai(df / 2.0, 0.5, x)
    return 1 - p if t > 0 else p


# ---- 主流程 ----

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    for path in sys.argv[1:]:
        by = load(path)
        print(f"\n=== {path} ===")
        for mode in ("MAIN", "CTRL"):
            d = describe(by[mode])
            if not d:
                print(f"  {mode}: 无数据")
                continue
            print(f"  {mode}: n={d['n']:>6}  mean={d['mean']:7.4f}  sd={d['sd']:6.4f}  "
                  f"median={d['median']:>3}  max={d['max']:>3}  "
                  f">=10: {d['ge10']}/{d['n']} ({100*d['ge10']/d['n']:.1f}%)  "
                  f">=30: {d['ge30']}/{d['n']}")
        m, c = describe(by["MAIN"]), describe(by["CTRL"])
        if m and c and c["mean"] > 0:
            print(f"  MAIN/CTRL 倍数 = {m['mean']/c['mean']:.1f}x")

    if len(sys.argv) == 3:
        a, b = load(sys.argv[1]), load(sys.argv[2])
        t, df, p = welch(a["MAIN"], b["MAIN"])
        print(f"\n=== Welch t 检验（MAIN）===")
        print(f"  {sys.argv[1]} vs {sys.argv[2]}")
        print(f"  t = {t:.2f}, df = {df:.1f}, p = {p:.4f}  ->  "
              f"{'无显著差异' if p > 0.05 else '显著差异'}")
        sa, sb = describe(a["MAIN"]), describe(b["MAIN"])
        if sa and sb and sb["sd"] > 0:
            print(f"  方差比 = {(sa['sd']/sb['sd'])**2:.1f}x")

    return 0


if __name__ == "__main__":
    sys.exit(main())
