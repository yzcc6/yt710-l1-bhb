# Spectre-BHB 复现（Yitian 710 / Neoverse-N2）

> 维护者：ZYW（GitHub [@yzcc6](https://github.com/yzcc6)） · 索引仓：[`illustager/yt710-sca-hub`](https://github.com/illustager/yt710-sca-hub)（本仓库作为 `Spectre/` 下的 submodule 登记）

---

## TL;DR

在倚天 710（Neoverse-N2，aarch64，EL0 同特权）上**复现 Spectre-BHB 原语**：

用可控的分支链污染 BHB，使本进程的间接跳转**瞬态误跳**到泄露 gadget，再用 L1D Flush+Reload 读出本进程已知靶。

| 指标 | 结果 |
|---|---|
| **主结果**（`HISTORY_SIZE=256`，原地） | MAIN **17.99%**，最大单轮 59/100，`hits≥10` 占 **80.0%** |
| **配对对照** | CTRL **0.064%** → **283 倍** 差异；20 万轮中 CTRL **从未** `hits≥10` |
| **异地对照** | **0 / 4,600 万次测量**（H=256 的 600 万 + H=64 的 4000 万） |
| **探针自检** | hot 1 tick / cold 7 tick，**3~6 tick 无样本**，分离比 7.00×，阈值取 4 |
| 判定 | `status = success`，`failure_mode = null` |

**参数取值 `HISTORY_SIZE = 256`**：由 16 点扫描标定（256~288 为平台），上游默认 64 仅 0.58%。标定细节见 [§7](#7-参数标定history_size)。

> 范围：**同进程、同特权自测**。不涉及跨进程 / 跨特权 / VM / 租户；不改内核、不关缓解。
> 原语本体（`snippet.S` 三 gadget、JIT、训练/触发时序）**未改**，本仓库只做最小移植 + 测量脚手架。

上游：[`vusec/bhi-spectre-bhb`](https://github.com/vusec/bhi-spectre-bhb) `@ 4f64580`（= tag `ae_final`），目录 `re/arm/bhb_brute_force`。

---

## 1. 结论一览

| # | 结论 | 证据 | 可信度 |
|---|---|---|---|
| 1 | **BHB 可控瞬态执行原语在 N2 上存在** | MAIN 17.99% vs CTRL 0.064%（283×） | 强 |
| 2 | **信号由"训练目标"决定，非测量偏差** | 同链双测；CTRL 的 `≥10` 在 20 万轮中为 0 | 强 |
| 3 | **效应依赖"最后一条地址复用"** | 异地 4600 万次 = 0 | 强 |
| 4 | **链长存在最优区** | 16 点扫描，平台 256~288 | 中（平台内单点不可分辨） |
| 5 | **`HISTORY_SIZE=256` 远优于上游默认 64** | 17.99% vs 0.58%（约 29 倍） | 强 |
| 6 | 该值 ≠ PHR 物理深度（≈64） | 内核 + 文献交叉 | 中（未实测物理深度） |

---

## 2. 范围与红线

| 项 | 内容 |
|---|---|
| 特权级 | 同进程、同特权（EL0 用户态） |
| 攻击面 | 仅本进程内：BHB 污染 → 间接跳转瞬态误跳 → 读出本进程已知靶 |
| 不在范围 | 跨进程 / 跨特权（用户→内核）/ VM / 跨租户 |
| 不改动 | 内核、缓解开关、系统配置 |
| 未执行 | `re/arm/bhi_test`（跨特权验证，需定制内核，属 E005） |

---

## 3. 环境

| 项 | 值 |
|---|---|
| 平台 | 阿里云 ECS，4 vCPU / 16 GiB / 40 GiB |
| CPU | ARM Neoverse-N2（倚天 710），无 SMT |
| 频率 | 3000000 kHz 锁定，governor = performance |
| 内核 | `7.0.0-42-generic`，Ubuntu 26.04 |
| 计时 | `cntvct_el0`，`cntfrq_el0 = 50 MHz` → **1 tick = 20 ns** |
| `dc civac` | **EL0 可执行**（多数系统上是特权指令） |
| `pmccntr_el0` | **不可读**（`perf_event_paranoid=4`）→ SIGILL |
| 缓解 | `spectre_v2: Mitigation: CSV2, BHB` |

详见 [`docs/environment.md`](docs/environment.md)。

---

## 4. 目录结构

```
.
├── README.md
├── src/
│   ├── calib.c                  # ★ 配对测量仪（本仓库核心）
│   ├── snippet.S                # 三 gadget（上游原样）
│   └── targets.h                # 含 YITIAN_710 块（THR=4）
├── patches/PATCH.md             # 两处移植补丁 + 实现陷阱
├── scripts/
│   ├── build_and_smoke.sh       # 编译 + ruler 自检
│   ├── run_repro.sh             # ★ 主实验：复现 17.99%
│   ├── run_history_grid.sh      # 链长扫描（§7 标定）
│   ├── run_repeats.sh           # 重复性
│   ├── run_controls.sh          # 三条对照
│   └── analyze_sweep.py         # 统计（均值/中位/≥10/Welch t）
├── data/
│   ├── main_result.csv          # ★ 主结果与标定汇总
│   ├── sweep_main.csv           # 16 点扫描
│   ├── repeats.csv              # 重复测量
│   ├── controls.csv             # 对照汇总
│   └── README.md
└── docs/
    ├── environment.md
    ├── deliverables/            # 实验卡片 + 四件套（env/summary/README）
    ├── figs/                    # 5 张实测截图
    └── reports/
        ├── L1-1_最终报告_定稿.md
        └── HISTORY_SIZE_测量报告.md
```

---

## 5. 复现

### 构建

```bash
git clone https://github.com/vusec/bhi-spectre-bhb && cd bhi-spectre-bhb
git checkout ae_final
cd re/arm/bhb_brute_force

cp /path/to/this/src/calib.c    src/calib.c
cp /path/to/this/src/snippet.S  src/snippet.S      # 与上游一致，可先 diff
cp /path/to/this/src/targets.h  ../../../common/targets.h
# 按 patches/PATCH.md 补丁1 手改 ../../../common/helper.h 的计时源（pmccntr → cntvct，删两次 fence）

gcc -c src/snippet.S -o snippet.o -I../../../common -DYITIAN_710
gcc src/calib.c -o calib snippet.o -pie -O1 -I../../../common -DYITIAN_710
```

或一键：

```bash
./scripts/build_and_smoke.sh
```

### 主实验（复现 17.99%）

```bash
taskset -c 3 ./calib --history 256 --in-place 1 \
    --hit-num 200 --rounds 1000 --iters 100 --out final_256.csv
```

规模：200 条训练链 × 1000 条触发链 × 2 模式 × 100 次 = **4000 万次测量**（约 15 分钟）。

### 预期输出

```text
[ruler] cached=1.33 flushed=8.15 THR=4 OK
[cfg] history=256 hit_num=200 rounds=1000 iters=100 thr=4 in_place=1 tail_match=1 total_meas=40000000
[progress] 25/200
[progress] 50/200
[progress] 75/200
[progress] 100/200
```

统计：

```bash
awk -F, 'NR>1&&$4=="MAIN"{n++;s+=$6;if($6>m)m=$6;if($6>=10)g++;if($6>=51)h++}
     END{printf "MAIN  n=%d 均值=%.4f 最大=%d >=10:%d(%.1f%%) >=51:%d\n",n,s/n,m,g,100*g/n,h}' final_256.csv
awk -F, 'NR>1&&$4=="CTRL"{n++;s+=$6;if($6>m)m=$6;if($6>=10)g++}
     END{printf "CTRL  n=%d 均值=%.4f 最大=%d >=10:%d\n",n,s/n,m,g}' final_256.csv
```

**应得到**（本机实测）：

```text
MAIN  n=200000 均值=17.9870 最大=59 >=10:160021(80.0%) >=51:38
CTRL  n=200000 均值=0.0635 最大=3 >=10:0
```

截图见 [`docs/figs/fig2_main.png`](docs/figs/fig2_main.png)。

---

## 6. 方法

### 6.1 为什么另写一个仪器

上游 `main.c` 有三个设计缺陷，导致结论不可复现：

| # | 缺陷 | 后果 |
|---|---|---|
| 1 | **一次运行只抽 1 条训练链**（`hit_history` 开头生成一次，整轮不变） | 整个 run 只回答"这一条链行不行"，运行间方差极大（同一配置见过 0 / 3 / 42 次） |
| 2 | 没有零假设分布 | 看到 `hits=51` 不知道"纯噪声能到多少" |
| 3 | 没有配对对照 | 只能比较不同时间的两次运行 |

`calib.c`：**每条训练链单独随机抽样** + **同一条触发链测两遍**（训练到攻击目标 / 安全目标），顺序随机化并记录。

### 6.2 一次测量

```
① 训练：MAIN 训练到 ftable[1]（攻击目标）；CTRL 训练到 ftable[0]（安全目标）
② 冲刷：dc civac × 3（ftable[0]、ftable[1]、fr_buf）
③ 触发：ret_ptr(&ftable[0], fr_buf)     ← 两种模式完全相同
④ 计时：load_time(fr_buf) < THR(4 tick) → 记一次"命中"
```

**统计单位是"轮"，不是"次"**：1 轮 = 一条触发链 × 100 次测量 → `hits`（0~100）。
同一轮内的 100 次共用同一条链，**不独立**；把 4000 万次当样本会构成伪重复。

### 6.3 三条独立对照

| 对照 | 只改了什么 | 结果 | 排除了什么 |
|---|---|---|---|
| **CTRL** | 训练目标（安全 vs 攻击） | 17.99% vs 0.064%（283×），CTRL 的 `≥10` 在 20 万轮中为 **0** | 测量偏差 / 假阳性 |
| **异地**（`--in-place 0`） | 最后一条地址是否复用 | **0 / 4600 万次** | 链长 / 执行量的副作用 |
| **tail-match 1→64** | 复用尾部条数 | 16.6~20.4，**无单调趋势** | "PHR 足迹匹配数"解释 |

---

## 7. 参数标定（`HISTORY_SIZE`）

> 这是**主实验之后的补充标定**，不是主实验本身。

### 7.1 扫描结果（16 点）

| H | MAIN 均值 | 最大 | `≥10` 轮数 |
|---|---|---|---|
| 32 | 0.19 | 14 | 1 / 30,000 |
| 64（**上游默认**） | **0.58** | 43 | 59 / 30,000 |
| 128 | 3.76 | 68 | 4,876 / 30,000 |
| 192 | 7.36 | 38 | 9,272 / 30,000 |
| **256** | **16.60** | 53 | 22,307 / 30,000 |
| **288** | **17.33** | 48 | 25,980 / 30,000 |
| 304 | 15.19 | — | — |
| 320 | 13.31 | 35 | 24,480 / 30,000 |
| 336 | 8.14 | — | — |
| 352 | 5.95 | 32 | 3,611 / 30,000 |
| 384 | 0.77 | 29 | 21 / 30,000 |
| 512 | 0.004 | 46 | 3 / 30,000 |

### 7.2 平台与重复性

| H | 重复测量均值 | σ | n |
|---|---|---|---|
| 256 | 18.53 | **1.70** | 5 |
| **288** | **17.09** | **0.51** | 6 |
| 304 | 15.19 | 1.28 | 3 |
| 320 | 10.68 | 1.89 | 3 |
| 336 | 8.14 | 0.54 | 3 |

- 256 vs 288：差 1.44，**Welch t 检验 p≈0.13，无显著差异**
- 288 vs 320：差 6.41，**p<0.01，显著下降**
- 方差比：**(1.70/0.51)² = 11.3，F 检验 p<0.05**

### 7.3 取值

**主实验用 256**（20 万轮，17.99%）。
**若追求重复性，288 更稳**（σ 0.51 vs 1.70）——两者统计上同水平，取哪个都在平台内。

### 7.4 与物理深度的关系

| 量 | 数值 | 定义 | 来源 |
|---|---|---|---|
| PHR 物理深度 | **≈64** | 硬件能存多少条分支足迹 | Linux 内核 `spectre_bhb_k32` + USENIX'25 的 k×2 规则 |
| `HISTORY_SIZE` | **256** | 灌进去多少条链 | 本仓库实测 |
| 清除循环次数 K | 32 | 内核冲 BHB 要跑几遍 | Arm 白皮书 / 内核 |

**三者不可互换。** 完整标定报告见 [`docs/reports/HISTORY_SIZE_测量报告.md`](docs/reports/HISTORY_SIZE_测量报告.md)。

### 7.5 与同组另一套仪器（`yt710-l1-bhb` by WFY）的交叉验证

| 口径 | 峰位 | 谁测的 |
|---|---|---|
| 碰撞概率（本仓库 `calib.c`） | **256~288** | 本方 256/288；对方独立跑得 272 |
| 复跑产率（`main.c`，`TRAIN=128`，四闸） | 208~224 | 对方 |

**差异来源**：训练强度（128 次 vs 1 次）+ 统计口径（过闸中位 vs 全体均值），非实验误差。
**共识取值：`256`**（两套仪器平台的交集）。

---

## 8. 理论分析

### 8.1 机制

BHB（Branch History Buffer）记录近期分支的"足迹"。攻击者先执行一条**可控的训练链**，让 BHB 被自己的足迹填满、并让预测器学到"这段历史 → 攻击目标"；随后执行一条**尾部地址相同**的触发链，使预测器把"新历史"误认成"旧历史"，从而把架构上应跳到安全目标的间接跳转，**投机地**导向 `hit_gadget`。

`hit_gadget` 在瞬态窗口内读 `fr_buf`（本进程已知靶），Flush+Reload 立即能测出它进过缓存。

### 8.2 两条被证伪的假说

| 假说 | 预测 | 实测 | 判定 |
|---|---|---|---|
| "最优链长 256~288 是 4×64 的折叠谐波" | 320（=5×64）应出现第二峰 | 320 = 10.68，是斜坡，**无第二峰** | ❌ 否定 |
| "碰撞概率 = PHR 历史足迹匹配数" | 尾部匹配 1→64 应大幅上升 | 16.6~20.4，**无单调趋势** | ❌ 否定 |

**为什么链长存在最优区，机制仍未查清**——这是本工作的主要遗留问题。

### 8.3 与 Spectre v2 的区别

| | 攻击者动的是什么 | 为什么难防 |
|---|---|---|
| Spectre v2 | 往 BTB 塞一个**假目标** | 可给条目打特权标签 |
| **BHI** | 不动目标，只动**"历史 → 答案"的对应关系** | 受害者命中**自己那条合法条目**，标签检查不适用 |

---

## 9. 交付物

按实验室 L1-1 规范产出的四件套 + 卡片，见 [`docs/deliverables/`](docs/deliverables/)：

| 文件 | 内容 |
|---|---|
| `card_L1-1.md` | 实验卡片（9 字段） |
| `env.json` | 环境快照（11 字段） |
| `summary.json` | 统计与判定（`status=success`、`failure_mode=null`） |
| `README.md` | 实验说明（方法、三条对照、限制、一行复现命令） |

**原始数据**（400,000 行逐轮数据等）不进 git，存放于实验机
`~/710_l1/L1-1/20261106_h256_inplace/`（19 个文件 / 34 MB）。
聚合结果见 [`data/`](data/)。

---

## 10. 限制

| # | 内容 |
|---|---|
| 1 | 同进程、同特权自测；未做跨特权 / 跨租户 |
| 2 | `HISTORY_SIZE` 与 PHR 物理深度的关系未查清；已排除两种解释 |
| 3 | 平台内单点（256 vs 288）在测量分辨率内不可分辨（±2 个百分点） |
| 4 | 未做链数敏感性分析（每档固定 100 条训练链 × 300 条触发链） |
| 5 | 云上 4 vCPU 共享；未验证宿主机迁移的影响 |
| 6 | 部分运行出现 ruler 异常（`cached` 2.6~2.8，正常 1.33），提示偶发干扰 |

---

## 11. 引用与许可

- 原语本体来自 [`vusec/bhi-spectre-bhb`](https://github.com/vusec/bhi-spectre-bhb) `@ ae_final`，遵循其原始许可；本仓库仅做 N2 移植与测量脚手架，`snippet.S` / gadget / JIT / 触发时序**未改**。
- 移植改造、`calib.c`、脚本与报告为实验室内部研究产物。
- 参数交叉依据：Linux 内核 [`arch/arm64/kernel/proton-pack.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/arch/arm64/kernel/proton-pack.c)；Zhu & Biondi, *Exploiting Inaccurate Branch History in Side-Channel Attacks*, USENIX Security 2025（[arXiv:2506.07263](https://arxiv.org/abs/2506.07263)）；Arm, *Spectre-BHB: Speculative Target Reuse Attacks* 白皮书。

> ⚠️ 仅用于授权的安全研究与复现，限本机同进程自测。
