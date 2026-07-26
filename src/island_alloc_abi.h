// island_alloc_abi.h - shared constants between the Ruby island
// allocation redirect (multiruby/alloc_redirect.h, force-included
// into every libruby + ext compile) and the engine core's resource
// reclaimer (src/ruby_instance.cpp).
//
// The contract: everything a Ruby VM instance allocates goes into
// one named Darwin malloc zone. Side resources that a zone free
// cannot return - pthread keys, mmap'd GC heap pages - are recorded
// as magic-tagged allocations INSIDE the same zone. At session
// retire the core finds the zone by name, walks its live
// allocations once, deletes the recorded keys, munmaps unmatched
// map records, and destroys the zone - returning every byte and
// every side resource the VM ever acquired, with zero knowledge of
// Ruby's internals.
//
// Records are identified by their leading 8-byte magic, not by
// allocation size (the allocator rounds sizes up to its quantum).

#ifndef MKXPZ_ISLAND_ALLOC_ABI_H
#define MKXPZ_ISLAND_ALLOC_ABI_H

#include <stdint.h>

// One zone name for whichever island is active: the instance
// manager guarantees a single session at a time, and the zone is
// destroyed at retire, before the next acquire can allocate.
#define MKXPZ_ISLAND_ZONE_NAME "mkxpz.ruby.island"

#define MKXPZ_ISLAND_KEYREC_MAGIC   0x4D4B5A4B45590001ULL /* "MKZKEY.." */
#define MKXPZ_ISLAND_MAPREC_MAGIC   0x4D4B5A4D41500001ULL /* "MKZMAP.." */
#define MKXPZ_ISLAND_UNMAPREC_MAGIC 0x4D4B5A554D410001ULL /* "MKZUMA.." */

typedef struct {
    uint64_t magic; // MKXPZ_ISLAND_KEYREC_MAGIC
    uint64_t key;   // pthread_key_t created by the island's Ruby
} MkxpzIslandKeyRec;

typedef struct {
    uint64_t magic; // MAPREC (mmap) or UNMAPREC (munmap tombstone)
    uint64_t addr;
    uint64_t len;
} MkxpzIslandMapRec;

#endif // MKXPZ_ISLAND_ALLOC_ABI_H
