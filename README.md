# L1-1H：N2 BHB 历史链长标定（Yitian 710 / Neoverse-N2）

> 维护者：ZYW（GitHub [@yzcc6](https://github.com/yzcc6)） · 索引仓：[`illustager/yt710-sca-hub`](https://github.com/illustager/yt710-sca-hub)（本仓库作为 `Spectre/` 下的 submodule 登记）

---

## TL;DR

在倚天 710（Neoverse-N2）上，用一套**配对测量仪**标定 Spectre-BHB 攻击 harness 的 **`HISTORY_SIZE`（BHB 分支链长度）**：

- 同一条触发链测两遍，**只改"训练到哪个目标"**：训练到攻击目标 **17.99%** vs 训练到安全目标 **0.064%**（**283 倍**），20 万轮里 CTRL 从未出现 `hits≥10`；
- 13 点扫描（32→512）呈"上升—平台—衰减"：**256~288 为平台**（17~21%），320 起显著下降（p<0.01），336 降至 8.14%；
- 上游默认值 **64** 在同平台只有 **0.58%**，**远非最优**；
- **工作点取 288**：与 256 均值无统计差异（p=0.13），但重复性显著更好（σ=0.51 vs 1.70，F 检验 p<0.05）；
- 该值**不等于**硬件 PHR 物理深度（后者 ≈ **64** 条，由 Linux 内核 + USENIX Sec'25 交叉推出）。

**状态：可用**。限制：同进程、同特权（EL0）自测；未做跨特权 / 跨租户；未改内核、未关缓解。

---

## 范围声明（勿越读）

| 项 | 内容 |
|---|---|
| 特权级 | 同进程、同特权（EL0 用户态） |
| 攻击面 | 仅本进程内：BHB 污染 → 间接跳转瞬态误跳 → L1D Flush+Reload 读出本进程已知靶 |
| 不在范围 | 跨进程 / 跨特权（用户→内核）/ VM / 跨租户；不改内核、不关缓解 |
| 原语本体 | `snippet.S` 三 gadget、JIT、训练/触发时序**未改**；本仓库只做最小移植 + 测量脚手架 |

上游：[`vusec/bhi-spectre-bhb`](https://github.com/vusec/bhi-spectre-bhb) `@ 4f64580`（= tag `ae_final`），目录 `re/arm/bhb_brute_force`。

> 同批次工作：同组 `yt710-l1-bhb` 用**另一套仪器**（`main.c`，复跑产率口径）测同一参数，两套结果已交叉验证，见 [§6](#6-与另一套仪器的交叉验证)。

---

## 目录结构

```
.
├── README.md                      # 本文件
├── src/
│   ├── calib.c                    # ★ 配对测量仪（本仓库的核心交付）
│   ├── snippet.S                  # 三 gadget 汇编（上游未改，用于 diff 核验）
│   └── targets.h                  # 目标宏表，含 YITIAN_710 块（THR=4）
├── patches/
│   └── PATCH.md                   # 打在上游的两处补丁 + 实现陷阱
├── scripts/
│   ├── build_and_smoke.sh         # 编译 + ruler 自检 + 冒烟
│   ├── run_history_grid.sh        # 16 点链长扫描
│   ├── run_repeats.sh             # 重复性测量（256/288/304/320/336）
│   ├── run_controls.sh            # 三条对照：异地 / tail-match / CTRL 提取
│   └── analyze_sweep.py           # 均值·中位·≥10 轮数·平台与斜率判定
├── data/
│   ├── sweep_main.csv             # 16 点扫描聚合
│   ├── repeats.csv                # 重复测量逐次值
│   ├── controls.csv               # 对照实验汇总
│   └── README.md                  # 数据说明（原始逐轮数据在服务器）
└── docs/
    ├── environment.md             # 环境实测值 + THR=4 依据 + 计时口径说明
    ├── figs/                      # 5 张实测截图
    └── reports/
        ├── HISTORY_SIZE_测量报告.md        # 本参数标定的完整报告
        └── L1-1_最终报告_定稿.md            # L1-1 阶段二总报告
```

---

## 环境

| 项 | 值 |
|---|---|
| 平台 | 阿里云 ECS，4 vCPU / 16 GiB / 40 GiB |
| CPU | ARM Neoverse-N2（倚天 710），无 SMT |
| 频率 | 3000000 kHz 锁定，governor = performance |
| 内核 | `7.0.0-42-generic`，Ubuntu 26.04 |
| 计时 | `cntvct_el0`，`cntfrq_el0 = 50 MHz` → **1 tick = 20 ns** |
| `dc civac` | **EL0 可执行**（实测；多数系统上它是特权指令） |
| `pmccntr_el0` | **不可读**（`perf_event_paranoid=4`）→ 读它 SIGILL / 退出码 132 |
| 缓解 | `spectre_v2: Mitigation: CSV2, BHB` |

详见 [`docs/environment.md`](docs/environment.md)。

---

## 复现

### 构建

```bash
git clone https://github.com/vusec/bhi-spectre-bhb && cd bhi-spectre-bhb
git checkout ae_final
cd re/arm/bhb_brute_force

cp /path/to/this/src/calib.c    src/calib.c
cp /path/to/this/src/snippet.S  src/snippet.S    # 先 diff 核验，应与上游一致
cp /path/to/this/src/targets.h  ../../../common/targets.h
# 按 patches/PATCH.md 补丁 1 手改 ../../../common/helper.h 的计时源

gcc -c src/snippet.S -o snippet.o -I../../../common -DYITIAN_710
gcc src/calib.c -o calib snippet.o -pie -O1 -I../../../common -DYITIAN_710
```

或直接：

```bash
./scripts/build_and_smoke.sh
```

### 运行

```bash
# 单点（约 2 分钟 / 600 万次测量）
taskset -c 3 ./calib --history 288 --in-place 1 --hit-num 100 --rounds 300 --iters 100 --out h288.csv

# 16 点扫描
./scripts/run_history_grid.sh

# 重复性
./scripts/run_repeats.sh

# 对照
./scripts/run_controls.sh

# 统计
python3 scripts/analyze_sweep.py h288.csv
```

### 参数

| 参数 | 含义 | 基线值 |
|---|---|---|
| `--history N` | 分支链长度（**自变量**） | 扫 32~512 |
| `--in-place 0\|1` | 触发链最后一条地址是否复用训练链 | 1（主）/ 0（对照） |
| `--tail-match N` | 复用尾部的地址条数 | 1（默认）/ 0 / 8 / 16 / 32 / 64 |
| `--hit-num M` | 不同训练链条数 | 100 |
| `--rounds R` | 每条训练链配多少条触发链 | 300 |
| `--iters K` | 每条触发链每种模式测多少次 | 100 |
| `--thr T` | 命中阈值（tick） | **4** |
| `--out FILE` | 聚合输出 | — |

**统计单位是"轮"，不是"次"**：1 轮 = 一条触发链 × K 次测量 → `hits`（0~K）。同一轮内的 K 次共用同一条链，不独立。

### 预期输出

真实运行（`--history 288 --hit-num 100 --rounds 300 --iters 100`）：

```text
[ruler] cached=1.33 flushed=8.15 THR=4 OK
[cfg] history=288 hit_num=100 rounds=300 iters=100 thr=4 in_place=1 tail_match=1 total_meas=6000000
[progress] 25/100
[progress] 50/100
[progress] 75/100
[progress] 100/100
```

`h288.csv` 内容形如：

```text
hit_id,round,order,mode,iters,hits,min_dt,max_dt
0,0,MA,MAIN,100,23,1,12
0,0,AM,CTRL,100,0,7,14
0,1,AM,MAIN,100,17,1,11
...
```

**关键指标**：

| 指标 | 含义 | 参考值（H=288） |
|---|---|---|
| `mode=MAIN` 的 `hits` 均值 | 训练到攻击目标时的命中数 | **17.09** |
| `mode=CTRL` 的 `hits` 均值 | 训练到安全目标时的命中数 | ≈0.06 |
| `MAIN` 中 `hits≥10` 的轮占比 | "强碰撞"频率 | ≈62% |

---

## 理论分析

### 为什么需要另写一个仪器

上游 `main.c` 有三个设计缺陷，导致结论不可复现：

| # | 缺陷 | 后果 |
|---|---|---|
| 1 | **一次运行只抽 1 条训练链**（`hit_history` 开头生成一次，整轮不变） | 整个 run 只回答"这一条链行不行"，运行间方差极大（同一配置见过 0 / 3 / 42 次） |
| 2 | 没有零假设分布 | 看到 `hits=51` 不知道"纯噪声能到多少" |
| 3 | 没有配对对照 | 只能比较不同时间的两次运行 |

`calib.c` 的做法：**每条训练链单独随机抽样**，并且**同一条触发链测两遍**（训练到攻击目标 / 安全目标），顺序随机化并记录。

### 三条独立对照

| 对照 | 只改了什么 | 结果 | 排除了什么 |
|---|---|---|---|
| **CTRL** | 训练目标（安全 vs 攻击） | 17.99% vs 0.064%（283×）；CTRL 的 `≥10` 在 20 万轮中为 **0** | 测量偏差、假阳性 |
| **异地**（`--in-place 0`） | 最后一条地址是否复用 | **0 / 4600 万次测量** | 链长/执行量的副作用 |
| **tail-match 1→64** | 复用尾部条数 | 16.6~20.4，**无单调趋势** | "PHR 足迹匹配数"解释 |

### 两条被证伪的假说

1. **"288 = 4×64 折叠谐波"** —— 若成立，320（=5×64）应出现第二峰。实测 320 = 10.68（3 次），是斜坡，**无第二峰**。
2. **"碰撞 = PHR 历史足迹匹配数"** —— 若成立，尾部匹配 1→64 应使命中率大幅上升。实测无变化。

**机制仍未查清**，这是本工作的主要遗留问题（见报告 §9）。

### 物理深度 vs 链长

| 量 | 数值 | 定义 | 来源 |
|---|---|---|---|
| PHR 物理深度 | **≈64** | 硬件能存多少条分支足迹 | Linux 内核 `spectre_bhb_k32` + USENIX'25 的 k×2 规则 |
| `HISTORY_SIZE` | **288** | 灌进去多少条链 | 本仓库实测 |
| 清除循环次数 K | 32 | 内核冲 BHB 要跑几遍 | Arm 白皮书 / 内核 |

**三者不可互相换算。**

---

## 与另一套仪器的交叉验证

同组 `yt710-l1-bhb` 用改造版 `main.c` 测同一参数（口径：过闸样本的中位 %，`TRAIN=128`）：

| 口径 | 峰位 | 谁测的 |
|---|---|---|
| **碰撞概率**（本仓库 `calib.c`） | **256~288** | 本方 256/288；对方独立跑得 272 |
| 复跑产率（`main.c`） | 208~224 | 对方 |

**差异来源**：训练强度（`TRAIN=128` vs 1 次）+ 统计口径（过闸中位 vs 全体均值）。
**共识取值：`256`**（落在两套仪器的平台交集内）。

---

## 引用与许可

- 原语本体来自 [`vusec/bhi-spectre-bhb`](https://github.com/vusec/bhi-spectre-bhb) `@ ae_final`，遵循其原始许可；本仓库仅对其做 N2 移植与测量脚手架，`snippet.S` / gadget / JIT / 触发时序**未改**。
- 移植改造、`calib.c`、扫描/分析脚本与报告为实验室内部研究产物。
- 参数交叉依据：Linux 内核 [`arch/arm64/kernel/proton-pack.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/arch/arm64/kernel/proton-pack.c)；Zhu & Biondi, *Exploiting Inaccurate Branch History in Side-Channel Attacks*, USENIX Security 2025（[arXiv:2506.07263](https://arxiv.org/abs/2506.07263)）；Arm, *Spectre-BHB: Speculative Target Reuse Attacks* 白皮书。

> ⚠️ 仅用于授权的安全研究与复现，限本机同进程自测。
