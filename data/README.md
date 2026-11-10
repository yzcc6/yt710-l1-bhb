# 数据说明

本目录只放**聚合结果**（可直接用于作图/复核）。

## 文件

| 文件 | 内容 | 列 |
|---|---|---|
| `sweep_main.csv` | 16 点链长扫描 | `H, main_mean, main_max, main_ge10, main_ge30, note` |
| `repeats.csv` | 重复性测量（同参数多次运行） | `H, run, mean_hits` |
| `controls.csv` | 三条对照汇总 | `config, H, measurements, tail_match, mean_hits, note` |

**`main_mean` / `mean_hits` 的单位**：每轮命中次数（一轮 = 一条触发链 × 100 次测量，取值 0~100）。
除以 100 即为命中率百分比。

## 原始数据在哪

逐轮原始数据（每行 = 一条触发链 × 一种模式）**不进 git**（单个文件 1.5 MB × 20+），
保存在实验机：

```text
~/710_l1/bhi-spectre-bhb/re/arm/bhb_brute_force/
├── h32.csv ~ h512.csv          单次扫描
├── r256_1..5.csv               H=256 五次重复
├── b288_1..6.csv               H=288 六次重复
├── b304/b320/b336_1..3.csv     斜坡三档
├── h256_ip0.csv / h256_ip1.csv 异地 / 原地
└── m1/m8/m16/m32/m64.csv       tail-match
```

归档目录（含四件套）：`~/710_l1/L1-1/20261106_h256_inplace/`

原始行为格式：

```text
hit_id,round,order,mode,iters,hits,min_dt,max_dt
```

## 复现方式

见仓库根目录 `README.md` 与 `scripts/`。单点复现：

```bash
taskset -c 3 ./calib --history 288 --in-place 1 --hit-num 100 --rounds 300 --iters 100 --out h288.csv
python3 scripts/analyze_sweep.py h288.csv
```
