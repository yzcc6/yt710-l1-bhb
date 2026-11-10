## 卡片 L1-1：Spectre-BHB 基线（倚天 710 上 BHB 碰撞复现与参数标定）

> 本卡片覆盖 L1-1 的**阶段二（重做版）**。
> 阶段一（L1D Flush+Reload 探针）已在 `710_l1/L1-1/20261105_l1d_fr/card_L1-1.md` 中单独成卡。
> **流程说明**：按规范，卡片应在执行前填写完整；本卡片因需求变更（首版判 fail 后重做）为**执行后补录**，
> 所有参数与判据均与实际执行一致，未作事后调整。

- **目的**：验证在倚天 710（Neoverse-N2）上，攻击者可控的用户态分支历史能否污染 BHB，
> 使受害者的间接跳转被预测到攻击者指定的目标；并标定"哪些微架构参数必须按 N2 调整"。

- **输入参数（JSON）**：

  ```json
  {
    "history_size_sweep": [32, 48, 64, 96, 128, 160, 192, 256, 384, 512],
    "history_size_final": 256,
    "in_place": [1, 0],
    "iters_per_chain": 100,
    "hit_num_sweep": 100,
    "hit_num_final": 200,
    "rounds_sweep": 300,
    "rounds_final": 1000,
    "thr_tick": 4,
    "core_bind": 3
  }
  ```

- **前置检查**：
  1. `uname -m` = `aarch64`；`nproc` = 4；`taskset` 可用
  2. `cntfrq_el0` 可读且非 0（本机 50 MHz，1 tick = 20 ns）
  3. **`dc civac` 在 EL0 可用**（不可用则 Flush+Reload 不可行，需降级）
  4. `mmap(PROT_EXEC)` 可用（JIT 需要 RWX）
  5. **`pmccntr_el0` 不可读**（`perf_event_paranoid=4`），故计时必须用 `cntvct_el0`
  6. ruler 自检通过：程序内 `cached` 与 `flushed` 分离（本机 1.33 vs 8.10）
  7. 跑前 `uptime` 确认机器负载低

- **步骤**：
  1. 取基线：`vusec/bhi-spectre-bhb` @ `4f64580`（= tag `ae_final`）
  2. 应用两处移植：`common/helper.h`（`pmccntr_el0` → `isb; mrs cntvct_el0`，并移除两次 `fence()`）；
     `common/targets.h`（新增 `YITIAN_710` 块，`THR=4`）
  3. 编译：`gcc -c src/snippet.S -o snippet.o -I../../../common -DYITIAN_710`
     　　`gcc src/calib.c -o calib snippet.o -pie -O1 -I../../../common -DYITIAN_710`
  4. 冒烟：`./calib --history 64 --hit-num 2 --rounds 5 --iters 100 --in-place 1 --out smoke.csv`，
     确认表头为聚合格式且 ruler 通过
  5. **长度扫描**：`--history {32,48,64,96,128,160,192,256,384,512}`，每档 `--hit-num 100 --rounds 300`
  6. **决定性对照**：`--history 256 --in-place 0`（异地）与 `--in-place 1`（原地）各一组
  7. **主结果**：`--history 256 --in-place 1 --hit-num 200 --rounds 1000`
  8. 统计 MAIN / CTRL 的 `hits` 分布，导出 `raw.csv`

- **raw.csv 字段**：`hit_id`, `round`, `order`(MA/AM), `mode`(MAIN/CTRL), `iters`, `hits`, `min_dt`, `max_dt`

- **输出**：`env.json`、`raw.csv`、`summary.json`、`README.md`（本卡片同目录）

- **成功标准**（在本卡片填写时已固定，未事后调整）：
  1. **MAIN 命中率 ≥ CTRL 的 10 倍**（实测 283 倍）；
  2. **CTRL 在全部样本中 `hits ≥ 10` 的轮数为 0**（实测 0 / 200,000）；
  3. **异地对照命中数为 0**（实测 0 / 4,600 万次测量）；
  4. **`HISTORY_SIZE` 扫描呈单峰**，峰值位置可识别（实测峰值 256）。
  　补充：若上述 1~3 成立但 4 未出现单峰，仍可判 `success`，但需在 README 注明"最优长度未收敛"。

- **失败模式**：
  | 错误码 | 场景 | 本次是否触发 |
  |---|---|---|
  | `E001` | 编译失败（`CC_ANDROID` 为空） | 触发过，已用 `gcc` 覆盖解决 |
  | `E002` | 运行崩溃：`mrs pmccntr_el0` → SIGILL（退出码 132） | 触发过，已换 `cntvct_el0` |
  | `E003` | 计数器/PMU 不可读（`perf_event_paranoid=4`） | **成立**，故全程用 `cntvct` 软件计时 |
  | `E004` | 信号不可区分 | **未触发**（CTRL 与 MAIN 分布完全不相交） |
  | `E005` | 环境限制：`re/arm/bhi_test` 需定制内核 | **成立**，该实验未执行 |

- **负责人**：ZYW（与 WFY 共同负责 L1-1）
