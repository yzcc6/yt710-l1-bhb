/*
 * targets.h —— 目标平台宏表
 *
 * 本文件 = 上游 vusec/bhi-spectre-bhb @ ae_final 的 common/targets.h
 *          + 新增 YITIAN_710 块（仅此一处改动）
 *
 * 改动要点：
 *   1. 新增 #elif defined YITIAN_710
 *   2. THR 用 #ifndef 包住，允许编译期 -DTHR=4 覆盖（便于做 THR 稳健性）
 *   3. 不定义 HISTORY_SIZE —— 链长由 calib.c 的 --history 运行时指定
 */

#ifndef __TARGET_H__
#define __TARGET_H__

#define X64                 (0)
#define ARMV8               (1)
//An history size big enought that should work on any microarch
#define MAX_HISTORY_SIZE    (256)

#if   defined INTEL_10_GEN
#define ARCH            (X64)
#define HISTORY_SIZE    (29)
#ifndef THR
#define THR (160)
#endif
#define STRIDE          (4096)
#define PAGE_OFFSET     (0xffff888000000000ULL)

#elif defined INTEL_11_GEN
#define ARCH            (X64)
#define HISTORY_SIZE    (66)
#ifndef THR
#define THR (60)
#endif
#define STRIDE          (4096)
#define PAGE_OFFSET     (0xff11000000000000ULL)

#elif defined PIXEL_6
#define ARCH            (ARMV8)
#ifndef THR
#define THR (100)
#endif
#define STRIDE          (4096)
#define PHYS_OFFSET     (0x80000000LL)
#define PAGE_OFFSET     (0xffffff8000000000ULL)

#elif defined CUSTOM_UARCH
// HISTORY_SIZE: use re/bhb_size to find the value
// #define HISTORY_SIZE    (TODO)
// THR: use tools/fr_checker to find a good value
// #define THR             (TODO)
// #define ARCH            (TODO)
// #define STRIDE          (TODO)

#elif defined YITIAN_710
/* 倚天 710（Neoverse-N2），见 docs/environment.md
 *
 * THR = 4 依据：独立探针实测（docs/figs/fig1_probe.png）
 *   hot(命中)  min=1  median=1  max=2
 *   cold(未命中) min=7 median=7  max=14
 *   tick 3~6 无任何样本 → 分离比 7.00× → 阈值取 4
 * 注意：该阈值基于"删掉 rdtscp() 里两次 fence()"的计时口径；
 *   若保留 fence()，读数整体抬高（cached≈2.1 / flushed≈10.7），THR 需改 6。
 */
#define ARCH            (ARMV8)
#ifndef THR
#define THR (4)
#endif
#define STRIDE          (4096)
#define PHYS_OFFSET     (0x80000000LL)
#define PAGE_OFFSET     (0xffffff8000000000ULL)

#else
#error "Must specify a target"
#endif

#endif //__TARGET_H__
