// ruby_instance.cpp - per-session Ruby VM instance manager: the
// real-OS layer. All lifecycle decisions live in the OS-free state
// machine (island_state.h, unit-tested in tests/); this file supplies
// the ops - dlopen/dlclose, the RTLD_NOLOAD unload canary,
// copy-and-load, the Mach-O writable-segment snapshot/restore, the
// malloc-zone reclaim (island_alloc_abi.h), sigaction hygiene - plus
// the process-wide lock and the C API. See ruby_instance.h for the
// design rationale.

#include "ruby_instance.h"

#if MKXPZ_MOBILE

#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <copyfile.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/vm_prot.h>
#include <malloc/malloc.h>
#include "island_alloc_abi.h"
#endif

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "island_state.h"
#include "util/debugwriter.h"

// Static island entry points (merged.o, or the host app's
// NULL-returning stubs on framework-only builds). Declared here
// instead of via binding.h to avoid an include cycle (binding.h's
// iOS branch includes ruby_instance.h).
extern "C" ScriptBinding *mkxp_get_script_binding_18(void);
extern "C" ScriptBinding *mkxp_get_script_binding_19(void);
extern "C" ScriptBinding *mkxp_get_script_binding_31(void);

namespace {

// Guards all machine state. acquire/retire run on the RGSS thread;
// capability queries come from the host's main thread.
std::mutex s_mutex;

// ---------------------------------------------------------------------------
// Sigaction hygiene: ruby_init installs handlers (SEGV, PIPE, INT,
// ...) that would otherwise point into a retired - possibly unloaded
// - image. Snapshot at acquire, restore at retire.
// ---------------------------------------------------------------------------

struct sigaction s_savedSigactions[NSIG];
bool s_sigactionsSaved = false;

void opSaveSigactions(void *) {
    for (int sig = 1; sig < NSIG; ++sig)
        sigaction(sig, nullptr, &s_savedSigactions[sig]);
    s_sigactionsSaved = true;
}

void opRestoreSigactions(void *) {
    if (!s_sigactionsSaved)
        return;
    for (int sig = 1; sig < NSIG; ++sig) {
        if (sig == SIGKILL || sig == SIGSTOP)
            continue;
        sigaction(sig, &s_savedSigactions[sig], nullptr);
    }
    s_sigactionsSaved = false;
}

// ---------------------------------------------------------------------------
// Loader ops.
// ---------------------------------------------------------------------------

bool opResolveDylibPath(void *, int slot, std::string *outPath) {
#ifdef __APPLE__
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle)
        return false;
    CFURLRef fwURL = CFBundleCopyPrivateFrameworksURL(bundle);
    if (!fwURL)
        return false;
    char fwPath[1024] = {0};
    bool ok = CFURLGetFileSystemRepresentation(fwURL, true, (UInt8 *)fwPath,
                                               sizeof(fwPath));
    CFRelease(fwURL);
    if (!ok)
        return false;

    const char *suffix = mkxpi::IslandStateMachine::slotSuffix(slot);
    std::string path = std::string(fwPath) + "/RubyIsland" + suffix +
                       ".framework/RubyIsland" + suffix;
    struct stat st;
    if (stat(path.c_str(), &st) != 0)
        return false;
    *outPath = path;
    return true;
#else
    (void)slot;
    (void)outPath;
    return false;
#endif
}

void *opOpenImage(void *, int, const char *path) {
    void *handle = dlopen(path, RTLD_LOCAL | RTLD_NOW);
    if (!handle)
        Debug() << "ruby_instance: dlopen" << path << "failed:" << dlerror();
    return handle;
}

// Copy-and-load: a byte-identical copy at a unique path is a distinct
// dyld image with fresh statics. The copy keeps the original's
// embedded code signature (content-hashed, path-independent), and the
// file is unlinked right after load - the mapping survives, so there
// is no disk accumulation across sessions.
void *opOpenImageCopy(void *, int slot, const char *path, int generation) {
#ifdef __APPLE__
    const char *tmpDir = getenv("TMPDIR");
    if (!tmpDir || !tmpDir[0])
        tmpDir = "/tmp";
    char copyPath[1024];
    snprintf(copyPath, sizeof(copyPath), "%s/RubyIsland%s.gen%d.dylib",
             tmpDir, mkxpi::IslandStateMachine::slotSuffix(slot), generation);
    unlink(copyPath);
    if (copyfile(path, copyPath, nullptr, COPYFILE_ALL) != 0) {
        Debug() << "ruby_instance: copyfile to" << copyPath << "failed";
        return nullptr;
    }
    void *handle = dlopen(copyPath, RTLD_LOCAL | RTLD_NOW);
    unlink(copyPath);
    if (!handle)
        Debug() << "ruby_instance: dlopen (copy)" << copyPath
                << "failed:" << dlerror();
    return handle;
#else
    (void)slot;
    (void)path;
    (void)generation;
    return nullptr;
#endif
}

void opCloseImage(void *, void *handle) {
    dlclose(handle);
}

// Unload canary. RTLD_NOLOAD returns the existing handle (refcount
// bumped, balance it) when the image is still resident.
bool opImageResident(void *, const char *path) {
    void *probe = dlopen(path, RTLD_LOCAL | RTLD_LAZY | RTLD_NOLOAD);
    if (!probe)
        return false;
    dlclose(probe);
    return true;
}

void *opResolveBinding(void *, void *handle, int slot) {
    std::string sym = std::string("mkxp_get_script_binding_") +
                      mkxpi::IslandStateMachine::slotSuffix(slot);
    typedef ScriptBinding *(*EntryFn)(void);
    EntryFn entry = (EntryFn)dlsym(handle, sym.c_str());
    if (!entry) {
        Debug() << "ruby_instance: dlsym" << sym << "failed:" << dlerror();
        return nullptr;
    }
    return entry();
}

void *opStaticBinding(void *, int slot) {
    switch (slot) {
    case mkxpi::kSlot18: return mkxp_get_script_binding_18();
    case mkxpi::kSlot19: return mkxp_get_script_binding_19();
    default:             return mkxp_get_script_binding_31();
    }
}

// ---------------------------------------------------------------------------
// Stage 3 reset-in-place: pristine byte image of the canonical
// image's writable segments, captured after dlopen (static ctors
// done) but before the first ruby_init. Restoring every one of these
// puts the island's globals back into legal-first-ruby_init state.
// ---------------------------------------------------------------------------

struct SegmentSnapshot {
    void *base;
    size_t size;
    std::vector<unsigned char> bytes;
};

std::vector<SegmentSnapshot> s_segments[mkxpi::kSlotCount];

// Skipped segments: __DATA_CONST / __AUTH_CONST and anything with
// SG_READ_ONLY - dyld write-protects them after fixups (memcpy would
// fault) and their content never changes post-load, so there is
// nothing to restore. Zerofill (bss) sections live inside a
// segment's vmsize, so copying vmsize covers them.
bool opCaptureSnapshot(void *, int slot, void *addrInImage) {
#if defined(__APPLE__) && defined(__LP64__)
    Dl_info info;
    if (!dladdr(addrInImage, &info) || !info.dli_fbase)
        return false;
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)info.dli_fbase;
    if (header->magic != MH_MAGIC_64)
        return false;

    // slide = actual load address of __TEXT minus its stated vmaddr.
    uintptr_t slide = 0;
    bool haveSlide = false;
    const char *cursor = (const char *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_TEXT) == 0) {
                slide = (uintptr_t)header - (uintptr_t)seg->vmaddr;
                haveSlide = true;
                break;
            }
        }
        cursor += lc->cmdsize;
    }
    if (!haveSlide)
        return false;

    std::vector<SegmentSnapshot> &segments = s_segments[slot];
    segments.clear();
    cursor = (const char *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; ++i) {
        const struct load_command *lc = (const struct load_command *)cursor;
        cursor += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64)
            continue;
        const struct segment_command_64 *seg =
            (const struct segment_command_64 *)lc;
        if (!(seg->initprot & VM_PROT_WRITE) || seg->vmsize == 0)
            continue;
        if (seg->flags & SG_READ_ONLY)
            continue;
        if (strcmp(seg->segname, "__DATA_CONST") == 0 ||
            strcmp(seg->segname, "__AUTH_CONST") == 0)
            continue;
        SegmentSnapshot snap;
        snap.base = (void *)(seg->vmaddr + slide);
        snap.size = (size_t)seg->vmsize;
        snap.bytes.assign((unsigned char *)snap.base,
                          (unsigned char *)snap.base + snap.size);
        segments.push_back(std::move(snap));
    }

    if (segments.empty())
        return false;
    size_t total = 0;
    for (const SegmentSnapshot &s : segments)
        total += s.size;
    Debug() << "ruby_instance: island"
            << mkxpi::IslandStateMachine::slotSuffix(slot) << "snapshot:"
            << (int)segments.size() << "segments," << (int)(total / 1024)
            << "KiB";
    return true;
#else
    (void)slot;
    (void)addrInImage;
    return false;
#endif
}

// Preconditions owned by the state machine: the VM ran ruby_cleanup
// (island threads stopped), the instance is not poisoned, and the
// zone reclaim already returned the retired heap - so nothing can
// observe the restore mid-copy, and the orphaned heap is not
// referenced afterwards (restored statics hold pre-init values).
bool opRestoreSnapshot(void *, int slot) {
    std::vector<SegmentSnapshot> &segments = s_segments[slot];
    if (segments.empty())
        return false;
    for (const SegmentSnapshot &snap : segments)
        memcpy(snap.base, snap.bytes.data(), snap.size);
    return true;
}

void opDiscardSnapshot(void *, int slot) {
    s_segments[slot].clear();
}

// ---------------------------------------------------------------------------
// Zone reclaim: everything the retired VM allocated lives in one
// named malloc zone (multiruby/alloc_redirect.h routes every Ruby
// allocation entry point there), with pthread keys and mmap'd GC
// pages recorded as magic-tagged allocations inside it. One walk
// recovers the records; then keys are deleted, unmatched mappings
// munmapped, and the zone destroyed - the VM's entire footprint
// returned with zero knowledge of Ruby's internals.
// ---------------------------------------------------------------------------

#ifdef __APPLE__

struct ZoneScanState {
    std::vector<uint64_t> keys;
    std::vector<mkxpi::MapRange> maps;
    std::vector<mkxpi::MapRange> unmaps;
};

kern_return_t zoneScanReader(task_t, vm_address_t addr, vm_size_t,
                             void **out) {
    *out = (void *)addr; // in-process: memory is directly readable
    return KERN_SUCCESS;
}

void zoneScanRecorder(task_t, void *ctx, unsigned /*type*/,
                      vm_range_t *ranges, unsigned count) {
    ZoneScanState *state = (ZoneScanState *)ctx;
    for (unsigned i = 0; i < count; ++i) {
        // Allocation sizes are rounded up to the zone quantum, so
        // identify records by magic, not by exact size.
        if (ranges[i].size < sizeof(uint64_t))
            continue;
        const uint64_t magic = *(const uint64_t *)ranges[i].address;
        if (magic == MKXPZ_ISLAND_KEYREC_MAGIC &&
            ranges[i].size >= sizeof(MkxpzIslandKeyRec)) {
            state->keys.push_back(
                ((const MkxpzIslandKeyRec *)ranges[i].address)->key);
        } else if ((magic == MKXPZ_ISLAND_MAPREC_MAGIC ||
                    magic == MKXPZ_ISLAND_UNMAPREC_MAGIC) &&
                   ranges[i].size >= sizeof(MkxpzIslandMapRec)) {
            const MkxpzIslandMapRec *rec =
                (const MkxpzIslandMapRec *)ranges[i].address;
            mkxpi::MapRange range;
            range.addr = rec->addr;
            range.len = rec->len;
            (magic == MKXPZ_ISLAND_MAPREC_MAGIC ? state->maps : state->unmaps)
                .push_back(range);
        }
    }
}

#endif // __APPLE__

void opReclaimAllocations(void *) {
#ifdef __APPLE__
    vm_address_t *zones = nullptr;
    unsigned zoneCount = 0;
    if (malloc_get_all_zones(mach_task_self(), nullptr, &zones,
                             &zoneCount) != KERN_SUCCESS)
        return;
    malloc_zone_t *zone = nullptr;
    for (unsigned i = 0; i < zoneCount; ++i) {
        malloc_zone_t *z = (malloc_zone_t *)zones[i];
        const char *name = malloc_get_zone_name(z);
        if (name && strcmp(name, MKXPZ_ISLAND_ZONE_NAME) == 0) {
            zone = z;
            break;
        }
    }
    if (!zone)
        return; // session never allocated (e.g. pre-execute failure)

    ZoneScanState state;
    if (zone->introspect && zone->introspect->enumerator)
        zone->introspect->enumerator(mach_task_self(), &state,
                                     MALLOC_PTR_IN_USE_RANGE_TYPE,
                                     (vm_address_t)zone, zoneScanReader,
                                     zoneScanRecorder);

    for (uint64_t key : state.keys)
        pthread_key_delete((pthread_key_t)key);

    std::vector<mkxpi::MapRange> leftover =
        mkxpi::leftoverMappings(state.maps, state.unmaps);
    for (const mkxpi::MapRange &m : leftover)
        munmap((void *)(uintptr_t)m.addr, (size_t)m.len);

    malloc_destroy_zone(zone);
    Debug() << "ruby_instance: reclaimed island zone -"
            << (int)state.keys.size() << "pthread keys,"
            << (int)leftover.size() << "leftover mappings";
#endif
}

void opLog(void *, const char *msg) {
    Debug() << "ruby_instance:" << msg;
}

mkxpi::IslandStateMachine &machine() {
    static mkxpi::IslandStateMachine *m = [] {
        mkxpi::IslandOps ops;
        ops.openImage = opOpenImage;
        ops.openImageCopy = opOpenImageCopy;
        ops.closeImage = opCloseImage;
        ops.imageResident = opImageResident;
        ops.resolveBinding = opResolveBinding;
        ops.staticBinding = opStaticBinding;
        ops.resolveDylibPath = opResolveDylibPath;
        ops.captureSnapshot = opCaptureSnapshot;
        ops.restoreSnapshot = opRestoreSnapshot;
        ops.discardSnapshot = opDiscardSnapshot;
        ops.saveSigactions = opSaveSigactions;
        ops.restoreSigactions = opRestoreSigactions;
        ops.reclaimAllocations = opReclaimAllocations;
        ops.log = opLog;
        return new mkxpi::IslandStateMachine(ops);
    }();
    return *m;
}

} // namespace

extern "C" {

ScriptBinding *mkxpi_acquireRubyInstance(MKXPRubyVersion requested) {
    std::lock_guard<std::mutex> lock(s_mutex);
    return (ScriptBinding *)machine().acquire((int)requested);
}

ScriptBinding *mkxpi_currentScriptBinding(void) {
    return (ScriptBinding *)machine().currentBinding();
}

const char *mkxpi_rubyInstanceDiagnostics(void) {
    return machine().diagnostics();
}

void mkxpi_markRubyInstanceExecuting(void) {
    std::lock_guard<std::mutex> lock(s_mutex);
    machine().markExecuting();
}

void mkxpi_poisonActiveRubyInstance(void) {
    std::lock_guard<std::mutex> lock(s_mutex);
    machine().poison();
}

int mkxpi_hasStuckRubyInstance(void) {
    std::lock_guard<std::mutex> lock(s_mutex);
    return machine().hasStuckInstance() ? 1 : 0;
}

void mkxpi_retireRubyInstance(void) {
    std::lock_guard<std::mutex> lock(s_mutex);
    machine().retire();
}

void mkxpi_retireRubyInstanceIfUnexecuted(void) {
    std::lock_guard<std::mutex> lock(s_mutex);
    machine().retireIfUnexecuted();
}

MKXPSessionCapability mkxpi_sessionCapability(MKXPRubyVersion version) {
    std::lock_guard<std::mutex> lock(s_mutex);
    return (MKXPSessionCapability)machine().capability(
        (int)version, mkxp_isEngineTerminated() != 0);
}

} // extern "C"

#endif // MKXPZ_MOBILE
