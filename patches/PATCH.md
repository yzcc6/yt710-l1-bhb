# 打在上游 `vusec/bhi-spectre-bhb @ ae_final` 上的改动

> 全部改动 = **2 处补丁 + 1 个新文件**。`snippet.S`、`ind_gadget`/`hit_gadget`/`ret_gadget`、JIT 逻辑、训练/触发时序**一行未改**。

---

## 补丁 1：`common/helper.h` —— 计时源

**位置**：`rdtscp()` 函数的 `#elif ARCH == ARMV8` 分支。

**原因**：本机 `perf_event_paranoid=4`、`PMUSERENR_EL0.EN=0`，EL0 读 `pmccntr_el0` 直接 **SIGILL（退出码 132）**。

```diff
 #elif ARCH == ARMV8
     uint64_t result;
-    fence();
-    asm volatile("mrs %0, pmccntr_el0" : "=r" (result));
-    fence();
+    __asm__ __volatile__("isb\n\tmrs %0, cntvct_el0" : "=r" (result));
     return result;
```

### 为什么连两次 `fence()` 一起删

1. `fence()` = `dsb ish; isb`，单次几十 ns；`load_time()` 每次调用**两次** `rdtscp()`，屏障开销会被计入访问延迟；
2. **更关键**：`THR=4` 是在"只有 `isb`"的口径下测出来的。保留 `dsb` 会整体抬高读数（ruler 约 cached=2.1 / flushed=10.7），此时 `THR` 必须改 **6**。

> **两边比较时，计时口径必须一致**，否则 `hits` 不可比。

修改后 ruler 自检应输出：

```text
[ruler] cached=1.33 flushed=8.15 THR=4 OK
```

---

## 补丁 2：`common/targets.h` —— 新增 `YITIAN_710` 块

**位置**：插在 `#elif defined CUSTOM_UARCH` 之后、`#else` 之前。

```c
#elif defined YITIAN_710
#define ARCH            (ARMV8)
#ifndef THR
#define THR (4)
#endif
#define STRIDE          (4096)
#define PHYS_OFFSET     (0x80000000LL)
#define PAGE_OFFSET     (0xffffff8000000000ULL)
```

| 参数 | 取值 | 依据 |
|---|---|---|
| `ARCH` | `ARMV8` | 同为 arm64 |
| **`THR`** | **4** | 探针实测：hot=1 tick、cold=7 tick、**3~6 tick 无样本** |
| `STRIDE` | 4096 | 页大小 |
| `PHYS/PAGE_OFFSET` | 同上游 | 仅为让 `virt_to_physmap()` 通过编译，本实验不调用 |
| `HISTORY_SIZE` | **不定义** | 由 `calib.c --history` 运行时指定 |

本仓库已附完整 `src/targets.h`，可直接覆盖 `common/targets.h`。

---

## 新文件 3：`src/calib.c`

不修改上游 `main.c`，另立仪器。

### 它和上游 `main.c` 的区别

| | 上游 `main.c` | `calib.c` |
|---|---|---|
| 训练链 | 整轮只抽 1 条 | **每条单独抽样**（`--hit-num` 条） |
| 对照 | 无 | **同一条触发链测两遍**（MAIN / CTRL），顺序随机化 |
| 输出 | 逐次 `dt` | **逐轮聚合**（`hit_id,round,order,mode,iters,hits,min_dt,max_dt`） |
| 存储 | 每轮打印，易爆 | 聚合行，稳定 |

### 三个必须知道的实现点

**① `hit_ptr` 必须传槽位地址，不能传函数指针值**

```c
hit_ptr(&ftable[1], fr_buf);   // 正确
hit_ptr(ftable[1],  fr_buf);   // 错误：gadget 内部 ldr x0,[x0]; br x0
```

`ftable[1]` 是 `hit_gadget` 的地址；`&ftable[1]` 是这个地址**存放的位置**。gadget 会先 `ldr` 再 `br`，所以必须给地址的地址。

**② in-place 的含义**

```c
/* 触发链最后一条地址 = 训练链最后一条地址 */
ret_history[hist-1] = hit_history[hist-1];   /* --in-place 1 / --tail-match 1 */
```

漏掉这一条 → 变成"异地" → 两边全 0（本工作早期踩过：4000 万次测量全 0，差点误判"没有漏洞"）。

**③ `--tail-match N` 是诊断用**

复用训练链**尾部 N 条**地址（默认 1）。用于检验"匹配的历史足迹越多是否越容易撞"——实测 1→64 无变化，据此否定了该解释。

---

## 编译

```bash
cd re/arm/bhb_brute_force
gcc -c src/snippet.S -o snippet.o -I../../../common -DYITIAN_710
gcc src/calib.c -o calib snippet.o -pie -O1 -I../../../common -DYITIAN_710
```

> ⚠️ 上游 `Makefile` 用的是 `CC_ANDROID`（Android NDK 变量），直接 `make` 会失败；用 `make CC_ANDROID=gcc` 或直接 `gcc`。
