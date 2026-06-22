/* Clamp every system-memory value wine can read, so World Creator's startup
 * pool stays bounded. Wine derives GlobalMemoryStatusEx from two sources:
 *   - ullTotalPhys/AvailPhys      <- sysinfo()
 *   - ullTotalPageFile/commit     <- /proc/meminfo (CommitLimit, SwapTotal)
 * On a host with large swap both are huge (~165 GB here); WC sizes a native
 * pool to one of them and exhausts memory. Cap both to MEMCAP_GB and zero swap.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <sys/sysinfo.h>
#include <sys/syscall.h>

static unsigned long cap_kb(void) {
    const char *e = getenv("MEMCAP_GB");
    unsigned long gb = e ? strtoul(e, 0, 10) : 24;
    if (!gb) gb = 24;
    return gb * 1024UL * 1024UL;   /* kB */
}

int sysinfo(struct sysinfo *info) {
    static int (*real)(struct sysinfo *) = 0;
    if (!real) real = dlsym(RTLD_NEXT, "sysinfo");
    int r = real(info);
    if (r == 0 && info) {
        unsigned long unit = info->mem_unit ? info->mem_unit : 1;
        unsigned long cap = cap_kb() * 1024UL / unit;   /* cap in mem_unit units */
        if (info->totalram > cap) info->totalram = cap;
        if (info->freeram  > cap) info->freeram  = cap;
        info->totalswap = 0;
        info->freeswap  = 0;
    }
    return r;
}

/* Build a capped copy of /proc/meminfo in a fresh memfd. Uses raw syscalls so
 * it never re-enters the hooks below. */
static int capped_meminfo_fd(void) {
    int rfd = syscall(SYS_openat, AT_FDCWD, "/proc/meminfo", O_RDONLY, 0);
    if (rfd < 0) return -1;
    char buf[16384];
    ssize_t n = read(rfd, buf, sizeof(buf) - 1);
    close(rfd);
    if (n <= 0) return -1;
    buf[n] = 0;

    unsigned long cap = cap_kb();
    char out[16384];
    int oi = 0;
    char *line = buf, *nl;
    while (line && *line && oi < (int)sizeof(out) - 256) {
        nl = strchr(line, '\n');
        int len = nl ? (int)(nl - line) : (int)strlen(line);
        char tmp[256];
        if (len > 255) len = 255;
        memcpy(tmp, line, len);
        tmp[len] = 0;
        char key[64];
        unsigned long val;
        if (sscanf(tmp, "%63[^:]: %lu kB", key, &val) == 2) {
            int isswap = strncmp(key, "Swap", 4) == 0;
            unsigned long nv = isswap ? 0 : (val > cap ? cap : val);
            oi += snprintf(out + oi, sizeof(out) - oi, "%s: %8lu kB\n", key, nv);
        } else {
            oi += snprintf(out + oi, sizeof(out) - oi, "%s\n", tmp);
        }
        if (!nl) break;
        line = nl + 1;
    }
    int mfd = syscall(SYS_memfd_create, "meminfo", 0);
    if (mfd < 0) return -1;
    if (write(mfd, out, oi) != oi) { close(mfd); return -1; }
    lseek(mfd, 0, SEEK_SET);
    return mfd;
}

static int is_meminfo(const char *p) { return p && strcmp(p, "/proc/meminfo") == 0; }

#include <sys/mman.h>
#include <errno.h>
#include <stdatomic.h>

/* Optional cumulative ceiling on large (>=8MB) writable commits — anonymous
 * mmap, or mprotect adding PROT_WRITE (Wine's VirtualAlloc(MEM_COMMIT)).
 * MEMCAP_COMMIT_GB/MEMCAP_MMAP_GB set it; off by default. Cumulative, not
 * current, so it false-trips over a long session; did not bound the runaway. */
static atomic_long g_committed = 0;
static long commit_cap(void) {
    const char *e = getenv("MEMCAP_COMMIT_GB");
    if (!e) e = getenv("MEMCAP_MMAP_GB");
    return e ? strtol(e, 0, 10) * 1024L * 1024L * 1024L : 0;
}

static int over_cap(size_t len) {
    long cap = commit_cap();
    if (!cap) return 0;
    if (atomic_fetch_add(&g_committed, (long)len) + (long)len > cap) {
        atomic_fetch_sub(&g_committed, (long)len);
        /* MEMCAP_DEBUG: log rejections via raw write(2) (no allocator re-entry). */
        if (getenv("MEMCAP_DEBUG")) {
            char b[160];
            int n = snprintf(b, sizeof b,
                "[memcap] commit ceiling hit: req=%zuMB committed=%ldMB cap=%ldMB -> ENOMEM\n",
                len >> 20, (long)(atomic_load(&g_committed) >> 20), cap >> 20);
            if (n > 0) (void)write(2, b, (size_t)n);
        }
        errno = ENOMEM;
        return 1;
    }
    return 0;
}

/* MEMCAP_TRACE: log each writable commit >=1MB (size, flags, fd, anon) via raw
 * write(2), for diagnosing the runaway's allocation path. */
static void trace_commit(const char *what, size_t len, int prot, int flags, int fd) {
    if (len < (1UL << 20) || !getenv("MEMCAP_TRACE")) return;
    char b[200];
    int n = snprintf(b, sizeof b, "[memcap-trace] %s len=%zuMB prot=0x%x flags=0x%x fd=%d anon=%d\n",
                     what, len >> 20, prot, flags, fd, (flags & MAP_ANONYMOUS) ? 1 : 0);
    if (n > 0) (void)write(2, b, (size_t)n);
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    static void *(*real)(void *, size_t, int, int, int, off_t) = 0;
    if (!real) real = dlsym(RTLD_NEXT, "mmap");
    if (prot & PROT_WRITE) trace_commit("mmap", len, prot, flags, fd);
    if ((flags & MAP_ANONYMOUS) && (prot & PROT_WRITE) && len >= (8UL << 20) && over_cap(len))
        return MAP_FAILED;
    return real(addr, len, prot, flags, fd, off);
}

int mprotect(void *addr, size_t len, int prot) {
    static int (*real)(void *, size_t, int) = 0;
    if (!real) real = dlsym(RTLD_NEXT, "mprotect");
    if (prot & PROT_WRITE) trace_commit("mprotect", len, prot, 0, -1);
    if ((prot & PROT_WRITE) && len >= (8UL << 20) && over_cap(len))
        return -1;
    return real(addr, len, prot);
}

int open(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...) = 0;
    if (!real) real = dlsym(RTLD_NEXT, "open");
    if (is_meminfo(path) && getenv("MEMCAP_MEMINFO")) { int fd = capped_meminfo_fd(); if (fd >= 0) return fd; }
    va_list ap; va_start(ap, flags); mode_t m = va_arg(ap, int); va_end(ap);
    return real(path, flags, m);
}
int open64(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...) = 0;
    if (!real) real = dlsym(RTLD_NEXT, "open64");
    if (is_meminfo(path) && getenv("MEMCAP_MEMINFO")) { int fd = capped_meminfo_fd(); if (fd >= 0) return fd; }
    va_list ap; va_start(ap, flags); mode_t m = va_arg(ap, int); va_end(ap);
    return real(path, flags, m);
}
int openat(int dfd, const char *path, int flags, ...) {
    static int (*real)(int, const char *, int, ...) = 0;
    if (!real) real = dlsym(RTLD_NEXT, "openat");
    if (is_meminfo(path) && getenv("MEMCAP_MEMINFO")) { int fd = capped_meminfo_fd(); if (fd >= 0) return fd; }
    va_list ap; va_start(ap, flags); mode_t m = va_arg(ap, int); va_end(ap);
    return real(dfd, path, flags, m);
}
int openat64(int dfd, const char *path, int flags, ...) {
    static int (*real)(int, const char *, int, ...) = 0;
    if (!real) real = dlsym(RTLD_NEXT, "openat64");
    if (is_meminfo(path) && getenv("MEMCAP_MEMINFO")) { int fd = capped_meminfo_fd(); if (fd >= 0) return fd; }
    va_list ap; va_start(ap, flags); mode_t m = va_arg(ap, int); va_end(ap);
    return real(dfd, path, flags, m);
}
FILE *fopen(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *) = 0;
    if (!real) real = dlsym(RTLD_NEXT, "fopen");
    if (is_meminfo(path) && getenv("MEMCAP_MEMINFO")) { int fd = capped_meminfo_fd(); if (fd >= 0) return fdopen(fd, "r"); }
    return real(path, mode);
}
FILE *fopen64(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *) = 0;
    if (!real) real = dlsym(RTLD_NEXT, "fopen64");
    if (is_meminfo(path) && getenv("MEMCAP_MEMINFO")) { int fd = capped_meminfo_fd(); if (fd >= 0) return fdopen(fd, "r"); }
    return real(path, mode);
}
