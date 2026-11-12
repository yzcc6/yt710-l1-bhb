/*
 * bhb_final.c (v4) —— BHB 配对测量仪 · 合并版
 *
 * = 骨架（calib.c v3，ZYW）=
 *   · 每条训练链单独随机抽样（不是整轮只抽一条）
 *   · 同一条触发链测两遍：MAIN（训练到攻击目标）/ CTRL（训练到安全目标）
 *   · 顺序随机化并记录（order 列），可查顺序效应
 *   · 逐轮聚合 CSV，统计单位 = 轮（不是次，避免伪重复）
 *   · --history / --tail-match / --thr 运行时可调
 *
 * = 并入（main.c，WFY）=
 *   · [POS]  强制真跳正对照 —— 证明测量链路有效（期望 ~100%）
 *   · [SELF] 全同链自撞正对照 —— 证明 harness 能抓到瞬态
 *   · 闸门不合格即中止，避免跑出废数据
 *
 * = 新增（为了两人对跑可比）=
 *   · --train-n K   每次测量前训练几遍（默认 1；填 128 即可复现 WFY 的口径）
 *   · --seed N      固定随机种子（默认 time^pid）
 *   · [result] 行   跑完自动打印 MAIN/CTRL 均值与倍数
 *
 * 编译：
 *   gcc -c src/snippet.S -o snippet.o -I../../../common -DYITIAN_710
 *   gcc src/bhb_final.c -o bhb_final snippet.o -pie -O1 -I../../../common -DYITIAN_710
 *
 * 主实验（复现 17.99%）：
 *   taskset -c 3 ./bhb_final --history 256 --hit-num 200 --rounds 1000 --iters 100 --out final.csv
 *
 * 与 WFY 口径对跑（TRAIN=128）：
 *   taskset -c 3 ./bhb_final --history 224 --train-n 128 --hit-num 100 --rounds 300 --iters 50 --out w224.csv
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

#define B_OPCODE          (0x14000000U)
#define B_OFF_MASK_OPC    (0x03ffffffU)
#define B_OFF_MASK        (0x01ffffffU)
#define MAX_MEM           (0x04000000<<2)
#define BHI_ENABLE_SYSCALL 442
#define MAXH              1024

typedef uint64_t (*t_chain)(void *target, void *arg);
typedef void     (*t_target)(void *target);

extern void ret_gadget(void *arg);
extern void hit_gadget(void *arg);
extern void ind_gadget(void *arg);

static t_target ftable[2] = { &ret_gadget, hit_gadget };
static uint8_t *g_mem;

/* ---------------- JIT 与链生成（与上游一致） ---------------- */

static void jit(uint8_t *mem, const uint64_t *history, int hist)
{
    for (int i = 0; i < hist - 1; i++) {
        uint32_t offset = (uint32_t)((history[i+1] >> 2) - (history[i] >> 2));
        uint32_t opcode = B_OPCODE | (offset & B_OFF_MASK_OPC);
        memcpy(&mem[history[i]], &opcode, 4);
        __clear_cache(&mem[history[i]], &mem[history[i] + 4]);
    }
    memcpy(&mem[history[hist-1]], (void *)&ind_gadget, 8);
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

/* ---------------- 主程序 ---------------- */

int main(int argc, char **argv)
{
    int hit_num = 50, rounds = 200, iters = 100, thr = THR;
    int raw = 0, hist_out = 0, in_place = 1, hist = 64;
    int tail_match = 1, train_n = 1;
    int selftest = 1, min_self = 20, min_pos = 95;
    long seed = -1;
    const char *outfile = NULL;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "--hit-num")    && i+1 < argc) hit_num    = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rounds")     && i+1 < argc) rounds     = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--iters")      && i+1 < argc) iters      = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--thr")        && i+1 < argc) thr        = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--history")    && i+1 < argc) hist       = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--in-place")   && i+1 < argc) in_place   = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--tail-match") && i+1 < argc) tail_match = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--train-n")    && i+1 < argc) train_n    = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--min-self")   && i+1 < argc) min_self   = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--min-pos")    && i+1 < argc) min_pos    = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed")       && i+1 < argc) seed       = atol(argv[++i]);
        else if (!strcmp(argv[i], "--out")        && i+1 < argc) outfile    = argv[++i];
        else if (!strcmp(argv[i], "--raw"))  raw = 1;
        else if (!strcmp(argv[i], "--hist")) hist_out = 1;
        else if (!strcmp(argv[i], "--no-selftest")) selftest = 0;
        else { fprintf(stderr, "bad arg %s\n", argv[i]); return 1; }
    }

    if (!in_place) tail_match = 0;
    if (hist < 4 || hist > MAXH) { fprintf(stderr, "--history 必须在 4..%d\n", MAXH); return 1; }
    if (tail_match > hist) tail_match = hist;
    if (train_n < 1) train_n = 1;

    syscall(BHI_ENABLE_SYSCALL);
    srand(seed >= 0 ? (unsigned)seed : (unsigned)time(NULL) ^ (unsigned)getpid());

    uint8_t *fr_buf = mmap(NULL, STRIDE, PROT_READ|PROT_WRITE,
                           MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE, -1, 0);
    if (fr_buf == MAP_FAILED) { perror("mmap fr_buf"); return 1; }
    memset(fr_buf, 0x41, STRIDE);

    g_mem = mmap(NULL, MAX_MEM, PROT_READ|PROT_WRITE|PROT_EXEC,
                 MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE, -1, 0);
    if (g_mem == MAP_FAILED) { perror("mmap jit"); return 1; }

    /* ---------- 闸门 1：ruler 自检 ---------- */
    {
        uint64_t hs = 0, cs = 0;
        for (int i = 0; i < 1000; i++) { maccess(fr_buf); hs += load_time(fr_buf); }
        for (int i = 0; i < 1000; i++) { clflush(fr_buf); fence(); cs += load_time(fr_buf); }
        double hc = (double)hs / 1000.0, cc = (double)cs / 1000.0;
        fprintf(stderr, "[ruler] cached=%.2f flushed=%.2f THR=%d %s\n",
                hc, cc, thr, (cc > hc + 2) ? "OK" : "FAIL:no-separation");
        if (cc <= hc + 2) {
            fprintf(stderr, "!! 计时不可分（cached≈flushed），中止\n");
            return 2;
        }
    }

    /* ---------- 闸门 2：POS / SELF 正对照 ----------
     * 注意：闸门用固定的训练次数（至少 8 次），与实验的 --train-n 解耦。
     * 原因：--train-n 1 时预测器只被喂一遍，SELF 本身就不稳（实测 6%~22% 波动），
     *       闸门若跟着实验参数走，会误伤正常实验。
     */
    if (selftest) {
        int tn_gate = (train_n < 8) ? 8 : train_n;
        uint64_t sc[MAXH];
        gen_history(sc, hist, NULL, 0);
        jit(g_mem, sc, hist);
        t_chain sp = (t_chain)&g_mem[sc[0]];

        const int n = 1000;
        long pos = 0, self = 0;

        for (int i = 0; i < n; i++) {              /* POS：架构真跳 hit_gadget */
            for (int t = 0; t < tn_gate; t++) sp(&ftable[1], fr_buf);
            clflush(&ftable[0]); clflush(&ftable[1]); clflush(fr_buf);
            sp(&ftable[1], fr_buf);
            if (load_time(fr_buf) < (uint64_t)thr) pos++;
        }
        for (int i = 0; i < n; i++) {              /* SELF：全同链，投机跳 hit_gadget */
            for (int t = 0; t < tn_gate; t++) sp(&ftable[1], fr_buf);
            clflush(&ftable[0]); clflush(&ftable[1]); clflush(fr_buf);
            sp(&ftable[0], fr_buf);
            if (load_time(fr_buf) < (uint64_t)thr) self++;
        }

        double pp = 100.0 * pos / n, pf = 100.0 * self / n;
        fprintf(stderr, "[POS]  forced    = %ld/%d (%.1f%%)  期望 >=%d%%\n", pos, n, pp, min_pos);
        fprintf(stderr, "[SELF] same-chain= %ld/%d (%.1f%%)  期望 >=%d%%  (gate train_n=%d)\n",
                self, n, pf, min_self, tn_gate);

        if (pp < min_pos) {
            fprintf(stderr, "!! POS 不达标：测量链路失效（THR 或计时源），中止\n");
            return 3;
        }
        if (pf < min_self) {
            fprintf(stderr, "!! SELF 不达标：harness 抓不到瞬态（干扰/被缓解），中止\n"
                            "   确认环境正常后可用 --min-self 降低阈值重跑\n");
            return 4;
        }
    }

    FILE *fp = stdout;
    if (outfile) { fp = fopen(outfile, "w"); if (!fp) { perror("fopen"); return 1; } }

    if (raw)           fprintf(fp, "hit_id,round,order,mode,iter,dt\n");
    else if (hist_out) fprintf(fp, "hit_id,round,order,mode,dt,count\n");
    else               fprintf(fp, "hit_id,round,order,mode,iters,hits,min_dt,max_dt\n");

    fprintf(stderr, "[cfg] history=%d hit_num=%d rounds=%d iters=%d thr=%d train_n=%d "
                    "in_place=%d tail_match=%d seed=%s total_meas=%ld\n",
            hist, hit_num, rounds, iters, thr, train_n, in_place, tail_match,
            seed >= 0 ? "fixed" : "random",
            (long)hit_num * rounds * 2 * iters);

    uint64_t hit_history[MAXH], ret_history[MAXH];
    double sum_main = 0, sum_ctrl = 0;
    long n_main = 0, n_ctrl = 0;

    for (int h = 0; h < hit_num; h++) {
        gen_history(hit_history, hist, NULL, 0);
        jit(g_mem, hit_history, hist);
        t_chain hit_ptr = (t_chain)&g_mem[hit_history[0]];

        for (int r = 0; r < rounds; r++) {
            gen_history(ret_history, hist, hit_history, hist);
            for (int t = 0; t < tail_match; t++)
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
                    for (int t = 0; t < train_n; t++)
                        hit_ptr(tgt, fr_buf);
                    clflush(&ftable[0]);
                    clflush(&ftable[1]);
                    clflush(fr_buf);
                    ret_ptr(&ftable[0], fr_buf);
                    uint64_t dt = load_time(fr_buf);

                    if (dt < (uint64_t)thr) hits++;
                    if (dt < mn) mn = dt;
                    if (dt > mx) mx = dt;
                    if (raw)      fprintf(fp, "%d,%d,%s,%s,%d,%lu\n", h, r, order, mode, k, (unsigned long)dt);
                    if (hist_out) cnt[dt < 99 ? dt : 99]++;
                }

                if (is_main) { sum_main += hits; n_main++; }
                else         { sum_ctrl += hits; n_ctrl++; }

                if (hist_out) {
                    for (int t = 0; t < 100; t++)
                        if (cnt[t]) fprintf(fp, "%d,%d,%s,%s,%d,%u\n", h, r, order, mode, t, cnt[t]);
                } else if (!raw) {
                    fprintf(fp, "%d,%d,%s,%s,%d,%ld,%lu,%lu\n",
                            h, r, order, mode, iters, hits, (unsigned long)mn, (unsigned long)mx);
                }
            }
        }
        if ((h + 1) % 25 == 0) fprintf(stderr, "[progress] %d/%d\n", h + 1, hit_num);
    }

    if (!raw && !hist_out && n_main && n_ctrl) {
        double m = sum_main / n_main, c = sum_ctrl / n_ctrl;
        fprintf(stderr, "\n[result] MAIN n=%ld mean=%.4f | CTRL n=%ld mean=%.4f | ratio=%.1fx\n",
                n_main, m, n_ctrl, c, c > 0 ? m / c : 0.0);
    }

    if (fp != stdout) fclose(fp);
    return 0;
}
