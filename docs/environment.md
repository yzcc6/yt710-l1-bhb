# 环境实测值

> 采集时间：2026-11（L1-1 阶段二）
> 采集方式：手工执行 §6 的命令并核对；完整快照（JSON）在实验机 `~/710_l1/L1-1/20261106_h256_inplace/env.json`

---

## 1. 平台

| 项 | 实测值 | 说明 |
|---|---|---|
| 机器 | 阿里云 ECS，主机名 `lab-g8y` | — |
| CPU | ARM **Neoverse-N2**（倚天 710） | `lscpu` → `Model name: Neoverse-N2` |
| 核数 | 4 vCPU，1 thread/core（**无 SMT**） | `nproc` = 4 |
| 频率 | 3000000 kHz 锁定 | governor = `performance` |
| 内存/磁盘 | 16 GiB / 40 GiB | — |
| 内核 | `7.0.0-42-generic` | Ubuntu 26.04 |
| 绑核 | `taskset -c 3` | 全程固定单核 |

## 2. 计时与缓存指令

| 项 | 实测值 | 影响 |
|---|---|---|
| `cntfrq_el0` | **50000000**（50 MHz） | **1 tick = 20 ns**，是全部计时的基准 |
| `cntvct_el0` | 可读 | 本实验唯一可用的计时源 |
| `pmccntr_el0`（PMU） | **不可读** | `perf_event_paranoid=4`、`PMUSERENR_EL0.EN=0`；读它 → **SIGILL，退出码 132** |
| `dc civac`（arm64 的 clflush） | **EL0 可执行** | 多数系统上它是特权指令；本机实测可用 → Flush+Reload 可行 |
| `mmap(PROT_EXEC)` | 可用 | JIT 需要 RWX |

## 3. 缓解状态

```text
spectre_v1: Mitigation: __user pointer sanitization
spectre_v2: Mitigation: CSV2, BHB
```

- 无 `spectre_bhb` sysfs 文件
- 不关缓解、不改内核（红线）
- **注意**：本实验是**同进程、同特权**自测，跨特权缓解（如 ECBHB / ClearBHB）不影响测量；但这也意味着**本结果不能直接外推到跨特权场景**

## 4. `THR = 4` 的依据

独立探针 `probe.c`（Flush+Reload 双峰自检），`taskset -c 3` 实测：

```text
ruler: cached=1.33  flushed=8.15  (tick)

        min   median   max
hot(命中)    1      1      2
cold(未命中) 7      7     14

hot 直方图（单位 tick）
   1 | ################################ 129
   2 | #################### 71

cold 直方图（单位 tick）
   7 | ############################# 120
   8 | ############### 62
   9 | 2
  12 | 2
  13 | # 7
  14 | # 7

分离比 (cold/hot) = 7.00 x
建议阈值 THR     = 4 tick
判定：正向结果  两个峰可区分
```

**结论：tick 3~6 无任何样本**（真正的双峰），阈值取中点 **4**。
截图见 `docs/figs/fig1_probe.png`。

### ⚠️ 计时口径依赖

上述 `THR=4` 基于**删除了 `rdtscp()` 里两次 `fence()`** 的口径（见 `patches/PATCH.md` 补丁 1）。

| 口径 | cached | flushed | 适用 THR |
|---|---|---|---|
| **无 fence（本仓库）** | 1.33 | 8.15 | **4** |
| 保留 `fence()`（`dsb ish`） | ≈2.1 | ≈10.7 | 6 |

**两种口径各自自洽，但阈值不可跨口径比较。** 与他人数据对比时，必须先对齐口径。

## 5. 与同组另一套仪器（`yt710-l1-bhb`）的差异

| 项 | 本仓库 `calib.c` | `yt710-l1-bhb` `main.c` |
|---|---|---|
| 训练强度 | 1 次/测量 | **128 次/测量**（`TRAIN=128`） |
| 训练链抽样 | 每条单独抽（`--hit-num` 条） | 每 run 抽 1 条 |
| 指标 | 全体轮次 `hits` 均值 | 过闸样本中位 % |
| 闸门 | 无 | `SELF≥30 && CTRL≤2 && POS≥99` |
| 迭代 | `--iters 100` | `ITER=50` |
| **实测峰位** | **256~288** | **208~224** |

**两套差 60~80 个长度单位，主因是训练强度与统计口径，不是实验误差。**
交叉验证细节见根目录 `README.md` §6。

## 6. 可复现的环境快照

```bash
# 采集
uname -a
lscpu | grep -E 'Model name|CPU\(s\)|Thread'
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
cat /proc/sys/kernel/perf_event_paranoid
grep . /sys/devices/system/cpu/vulnerabilities/*
uptime

# 频率基准
python3 - <<'PY'
# cntfrq_el0 需在目标机上读；此处仅示意
print("cntfrq_el0 期望 50000000 -> 1 tick = 20 ns")
PY
```
