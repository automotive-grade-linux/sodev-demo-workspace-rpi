// SPDX-License-Identifier: Apache-2.0
/*
 * cgshim.c: force clock_gettime() through the raw
 * syscall, bypassing the aarch64 vDSO whose seqcount spins forever in this
 * dom0less direct-map DomD guest (confirmed: qemu hangs in userspace, R state,
 * wchan=0, syscall=running, inside cpu_enable_ticks' clock_gettime).
 *
 * Freestanding (-nostdlib): no libc/GLIBC version dependency so it loads under
 * any DomD glibc. Overrides the public clock_gettime symbol via LD_PRELOAD.
 *
 * aarch64 syscall numbers: clock_gettime=113, clock_getres=114, write=64.
 */

struct __ts { long tv_sec; long tv_nsec; };

static inline long sys2(long nr, long a0, long a1)
{
    register long x8 __asm__("x8") = nr;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1) : "memory", "cc");
    return x0;
}

int clock_gettime(int clk_id, struct __ts *tp)
{
    return (int)sys2(113, (long)clk_id, (long)tp);
}

int clock_getres(int clk_id, struct __ts *res)
{
    return (int)sys2(114, (long)clk_id, (long)res);
}

/* __clock_gettime alias some callers bind to */
int __clock_gettime(int clk_id, struct __ts *tp)
    __attribute__((alias("clock_gettime")));
