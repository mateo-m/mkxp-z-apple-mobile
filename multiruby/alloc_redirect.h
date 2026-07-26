// alloc_redirect.h - Ruby island allocation redirect.
//
// Force-included (-include) into every libruby + bundled-ext compile
// of the per-version Ruby island builds, and NOWHERE else. It routes
// every allocation entry point Ruby's C code uses into one private,
// named Darwin malloc zone, so that a game session's entire VM
// footprint can be returned in O(1) at retire
// (src/ruby_instance.cpp reclaims: delete recorded pthread keys,
// munmap unmatched map records, malloc_destroy_zone). See
// src/island_alloc_abi.h for the shared contract.
//
// Why this is safe against cross-boundary frees: Darwin's free(),
// realloc() and malloc_size() dispatch on the zone that owns the
// pointer. Island-zone memory freed by engine core, SDL, or libc
// internals lands back in the island zone; default-zone memory
// freed by Ruby lands back in the default zone. free/realloc are
// therefore intentionally NOT redirected (except realloc's
// realloc(NULL, n) == malloc case, handled in the wrapper so those
// allocations are island-tracked too).
//
// Why the header is fully self-contained (static inline, libSystem
// only): it must be force-includable into Ruby's ./configure test
// programs without introducing undefined symbols, or configure
// would silently misdetect features.
//
// The per-TU `cached` zone pointer lives in the island's __DATA and
// is wiped by the segment restore at retire - which is correct: the
// zone it pointed at was just destroyed, and the next session's
// first allocation re-creates a fresh one. First allocation happens
// during single-threaded VM boot (ruby_sysinit), which is what makes
// the create-if-missing lookup race-free in practice.
//
// IMPORTANT: every system header that declares one of the shadowed
// functions must be included BEFORE the macros are defined, so the
// declarations in those headers are not macro-expanded. Their
// include guards make later re-inclusion by Ruby a no-op.

#ifndef MKXPZ_ISLAND_ALLOC_REDIRECT_H
#define MKXPZ_ISLAND_ALLOC_REDIRECT_H

#if defined(__APPLE__)

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <malloc/malloc.h>

#include "../src/island_alloc_abi.h"

static inline malloc_zone_t *mkxpz_island_zone(void) {
    static malloc_zone_t *cached;
    if (cached)
        return cached;
    vm_address_t *zones = 0;
    unsigned count = 0;
    if (malloc_get_all_zones(mach_task_self(), 0, &zones, &count) ==
        KERN_SUCCESS) {
        unsigned i;
        for (i = 0; i < count; i++) {
            malloc_zone_t *z = (malloc_zone_t *)zones[i];
            const char *name = malloc_get_zone_name(z);
            if (name && strcmp(name, MKXPZ_ISLAND_ZONE_NAME) == 0) {
                cached = z;
                return z;
            }
        }
    }
    {
        malloc_zone_t *z = malloc_create_zone(0, 0);
        malloc_set_zone_name(z, MKXPZ_ISLAND_ZONE_NAME);
        cached = z;
        return z;
    }
}

static inline void *mkxpz_island_malloc(size_t n) {
    return malloc_zone_malloc(mkxpz_island_zone(), n);
}

static inline void *mkxpz_island_calloc(size_t c, size_t s) {
    return malloc_zone_calloc(mkxpz_island_zone(), c, s);
}

static inline void *mkxpz_island_valloc(size_t n) {
    return malloc_zone_valloc(mkxpz_island_zone(), n);
}

static inline void *mkxpz_island_realloc(void *p, size_t n) {
    // realloc(NULL, n) is malloc: route it into the zone. A non-NULL
    // pointer stays wherever it lives - libmalloc's realloc grows it
    // inside its owning zone.
    if (!p)
        return malloc_zone_malloc(mkxpz_island_zone(), n);
    return (realloc)(p, n);
}

static inline int mkxpz_island_posix_memalign(void **out, size_t align,
                                              size_t n) {
    void *p = malloc_zone_memalign(mkxpz_island_zone(), align, n);
    if (!p)
        return ENOMEM;
    *out = p;
    return 0;
}

static inline void *mkxpz_island_aligned_alloc(size_t align, size_t n) {
    return malloc_zone_memalign(mkxpz_island_zone(), align, n);
}

static inline char *mkxpz_island_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc_zone_malloc(mkxpz_island_zone(), n);
    if (p)
        memcpy(p, s, n);
    return p;
}

static inline char *mkxpz_island_strndup(const char *s, size_t max) {
    size_t n = strnlen(s, max);
    char *p = (char *)malloc_zone_malloc(mkxpz_island_zone(), n + 1);
    if (p) {
        memcpy(p, s, n);
        p[n] = '\0';
    }
    return p;
}

// getcwd(NULL, ...) / realpath(..., NULL) / vasprintf make libc
// allocate the result in the default zone. Copy into the island
// zone and release the original so the result is session-tracked.
static inline char *mkxpz_island_adopt(char *p) {
    char *copy;
    if (!p)
        return p;
    copy = mkxpz_island_strdup(p);
    if (!copy)
        return p; // keep the untracked original over failing
    (free)(p);
    return copy;
}

static inline char *mkxpz_island_getcwd(char *buf, size_t size) {
    char *r = (getcwd)(buf, size);
    if (buf)
        return r;
    return mkxpz_island_adopt(r);
}

static inline char *mkxpz_island_realpath(const char *path, char *resolved) {
    char *r = (realpath)(path, resolved);
    if (resolved)
        return r;
    return mkxpz_island_adopt(r);
}

static inline int mkxpz_island_vasprintf(char **out, const char *fmt,
                                         va_list ap) {
    int r = (vasprintf)(out, fmt, ap);
    if (r >= 0)
        *out = mkxpz_island_adopt(*out);
    return r;
}

static inline int mkxpz_island_asprintf(char **out, const char *fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = mkxpz_island_vasprintf(out, fmt, ap);
    va_end(ap);
    return r;
}

// pthread keys created by the VM (Init_native_thread & co) are
// process-global and capped at 512 on Darwin; without cleanup,
// "unlimited sessions" would abort after a few hundred. Record each
// create - and each delete, so reclaim never re-deletes a key number
// the VM already released (Darwin reuses slots; a blind re-delete
// could destroy a foreign library's live TLS key). Retire deletes
// keys whose create count exceeds their delete count (Ruby's keys
// have NULL destructors, so deletion is safe).
static inline void mkxpz_island_record_key(uint64_t magic, pthread_key_t key) {
    MkxpzIslandKeyRec *rec = (MkxpzIslandKeyRec *)malloc_zone_malloc(
        mkxpz_island_zone(), sizeof(MkxpzIslandKeyRec));
    if (rec) {
        rec->magic = magic;
        rec->key = (uint64_t)key;
    }
}

static inline int mkxpz_island_key_create(pthread_key_t *key,
                                          void (*dtor)(void *)) {
    int r = (pthread_key_create)(key, dtor);
    if (r == 0)
        mkxpz_island_record_key(MKXPZ_ISLAND_KEYREC_MAGIC, *key);
    return r;
}

static inline int mkxpz_island_key_delete(pthread_key_t key) {
    int r = (pthread_key_delete)(key);
    if (r == 0)
        mkxpz_island_record_key(MKXPZ_ISLAND_KEYDEL_MAGIC, key);
    return r;
}

// GC heap pages on 64-bit are mmap'd, bypassing malloc entirely -
// and Ruby's page allocator maps oversized regions, trims the
// misaligned head/tail with PARTIAL munmaps, and the kernel reuses
// addresses. So each call records an event stamped with
// mach_absolute_time(); the reclaimer sorts by time and replays the
// interval algebra (island_state.h replayMappings) to find what is
// genuinely still mapped. Append-only: no lookups on the hot path.
static inline void mkxpz_island_record_map(uint64_t magic, void *addr,
                                           size_t len) {
    MkxpzIslandMapRec *rec = (MkxpzIslandMapRec *)malloc_zone_malloc(
        mkxpz_island_zone(), sizeof(MkxpzIslandMapRec));
    if (rec) {
        rec->magic = magic;
        rec->addr = (uint64_t)(uintptr_t)addr;
        rec->len = (uint64_t)len;
        rec->time = mach_absolute_time();
    }
}

static inline void *mkxpz_island_mmap(void *addr, size_t len, int prot,
                                      int flags, int fd, off_t offset) {
    void *p = (mmap)(addr, len, prot, flags, fd, offset);
    if (p != MAP_FAILED)
        mkxpz_island_record_map(MKXPZ_ISLAND_MAPREC_MAGIC, p, len);
    return p;
}

static inline int mkxpz_island_munmap(void *addr, size_t len) {
    int r = (munmap)(addr, len);
    if (r == 0)
        mkxpz_island_record_map(MKXPZ_ISLAND_UNMAPREC_MAGIC, addr, len);
    return r;
}

#define malloc(n)                mkxpz_island_malloc(n)
#define calloc(c, s)             mkxpz_island_calloc(c, s)
#define valloc(n)                mkxpz_island_valloc(n)
#define realloc(p, n)            mkxpz_island_realloc(p, n)
#define posix_memalign(o, a, s)  mkxpz_island_posix_memalign(o, a, s)
#define aligned_alloc(a, s)      mkxpz_island_aligned_alloc(a, s)
#define strdup(s)                mkxpz_island_strdup(s)
#define strndup(s, n)            mkxpz_island_strndup(s, n)
#define getcwd(b, n)             mkxpz_island_getcwd(b, n)
#define realpath(p, r)           mkxpz_island_realpath(p, r)
#define asprintf(...)            mkxpz_island_asprintf(__VA_ARGS__)
#define vasprintf(p, f, a)       mkxpz_island_vasprintf(p, f, a)
#define mmap(a, l, pr, fl, fd, o) mkxpz_island_mmap(a, l, pr, fl, fd, o)
#define munmap(a, l)             mkxpz_island_munmap(a, l)
#define pthread_key_create(k, d) mkxpz_island_key_create(k, d)
#define pthread_key_delete(k)    mkxpz_island_key_delete(k)

#endif // __APPLE__

#endif // MKXPZ_ISLAND_ALLOC_REDIRECT_H
