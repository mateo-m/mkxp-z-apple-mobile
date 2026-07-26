// island_state.h - the Ruby instance manager's state machine,
// OS-free and header-only.
//
// Everything that decides WHICH freshness mechanism a session gets -
// canonical dlopen, reset-in-place, copy-and-load, static single-shot
// - and how acquire/retire/poison/capability interact, lives here,
// parameterized over an ops table. src/ruby_instance.cpp supplies the
// real ops (dlopen/dlclose, RTLD_NOLOAD canary, Mach-O segment
// snapshot, malloc-zone reclaim, sigaction save/restore) and the
// process-wide locking; tests/island_state_test.cpp supplies fakes
// and drives every lifecycle path. Keep this file free of OS and
// engine includes so the test suite compiles with a bare C++
// compiler on any host.
//
// Threading contract: callers serialize all calls (ruby_instance.cpp
// holds one mutex around every entry point). The only lock-free read
// is diagnostics(), which returns an atomically-published pointer to
// a fully written buffer.

#ifndef MKXPZ_ISLAND_STATE_H
#define MKXPZ_ISLAND_STATE_H

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace mkxpi {

// Mirrors MKXPSessionCapability (app_bridge.h) by value; kept as
// plain ints so this header stays engine-include-free.
enum : int {
    kCapFresh = 0,
    kCapDirty = 1,
    kCapUnavailable = 2,
};

// Slot indices. Fallback order (newest first) and the version->slot
// mapping mirror the historical dispatcher.
enum : int {
    kSlot18 = 0,
    kSlot19 = 1,
    kSlot31 = 2,
    kSlotCount = 3,
};

struct IslandOps {
    void *user = nullptr;

    // Loader.
    // Open the canonical image at `path`. Null on failure.
    void *(*openImage)(void *user, int slot, const char *path) = nullptr;
    // Copy `path` to a unique location, open the copy, unlink it.
    void *(*openImageCopy)(void *user, int slot, const char *path,
                           int generation) = nullptr;
    void (*closeImage)(void *user, void *handle) = nullptr;
    // Unload canary (balanced RTLD_NOLOAD probe): is the canonical
    // image still resident after closeImage?
    bool (*imageResident)(void *user, const char *path) = nullptr;
    // dlsym + call the island entry; returns the ScriptBinding* (as
    // void* to stay engine-include-free). Null on failure.
    void *(*resolveBinding)(void *user, void *handle, int slot) = nullptr;
    // The statically-linked entry for this slot (null when stubbed).
    void *(*staticBinding)(void *user, int slot) = nullptr;
    // Locate the island dylib for this slot. False when not shipped.
    bool (*resolveDylibPath)(void *user, int slot, std::string *outPath) = nullptr;

    // Stage 3 reset-in-place.
    bool (*captureSnapshot)(void *user, int slot, void *bindingAddr) = nullptr;
    bool (*restoreSnapshot)(void *user, int slot) = nullptr;
    void (*discardSnapshot)(void *user, int slot) = nullptr;

    // Session hygiene.
    void (*saveSigactions)(void *user) = nullptr;
    void (*restoreSigactions)(void *user) = nullptr;
    // Destroy the island malloc zone: delete recorded pthread keys,
    // munmap leftover pages, free the heap remainder.
    void (*reclaimAllocations)(void *user) = nullptr;

    void (*log)(void *user, const char *msg) = nullptr;
};

// Pure helpers for the zone reclaimer.

struct MapRange {
    uint64_t addr = 0;
    uint64_t len = 0;
};

// One recorded mmap/munmap call, stamped with a monotonic time
// (zone enumeration returns records in arbitrary order; only the
// timestamps recover the true sequence).
struct MapEvent {
    uint64_t addr = 0;
    uint64_t len = 0;
    uint64_t time = 0;
    bool unmap = false;
};

// Which address ranges are genuinely still mapped after the recorded
// history. This must be a faithful REPLAY with interval algebra, not
// record matching: Ruby's GC page allocator mmaps an oversized
// region and trims the misaligned head/tail with PARTIAL munmaps,
// frees pages with page-sized munmaps that never equal the original
// record, and the kernel reuses addresses across map/unmap cycles.
// Exact-match tombstones would report the original full ranges as
// leftover and munmap memory that was returned long ago - and
// possibly re-mapped by someone else since.
inline std::vector<MapRange> replayMappings(std::vector<MapEvent> events) {
    std::stable_sort(events.begin(), events.end(),
                     [](const MapEvent &a, const MapEvent &b) {
                         return a.time < b.time;
                     });

    // Live intervals as [start, end), keyed by start.
    std::map<uint64_t, uint64_t> live;

    auto subtract = [&live](uint64_t s, uint64_t t) {
        auto it = live.lower_bound(s);
        if (it != live.begin()) {
            auto prev = std::prev(it);
            if (prev->second > s)
                it = prev;
        }
        while (it != live.end() && it->first < t) {
            uint64_t ls = it->first;
            uint64_t le = it->second;
            it = live.erase(it);
            if (ls < s)
                live[ls] = s;
            if (le > t)
                live[t] = le; // tail remainder; lies before `it`
        }
    };

    for (const MapEvent &e : events) {
        if (e.len == 0)
            continue;
        const uint64_t s = e.addr;
        const uint64_t t = e.addr + e.len;
        // A new mapping implicitly replaces anything it overlaps
        // (the kernel did the same when it handed the address out).
        subtract(s, t);
        if (!e.unmap)
            live[s] = t;
    }

    std::vector<MapRange> result;
    for (const auto &kv : live) {
        MapRange r;
        r.addr = kv.first;
        r.len = kv.second - kv.first;
        result.push_back(r);
    }
    return result;
}

// Which pthread keys are still live after the recorded history:
// creates minus deletes per key number. Darwin reuses key slots, so
// a key the VM itself deleted must never be re-deleted by reclaim -
// the slot may since belong to a foreign library's live TLS key.
inline std::vector<uint64_t> liveKeys(const std::vector<uint64_t> &creates,
                                      const std::vector<uint64_t> &deletes) {
    std::map<uint64_t, int> net;
    for (uint64_t k : creates)
        net[k] += 1;
    for (uint64_t k : deletes)
        net[k] -= 1;
    std::vector<uint64_t> live;
    for (const auto &kv : net) {
        if (kv.second > 0)
            live.push_back(kv.first);
    }
    return live;
}

class IslandStateMachine {
public:
    explicit IslandStateMachine(const IslandOps &ops) : ops_(ops) {
        publish("no session yet");
    }

    static int slotForVersion(int version) {
        switch (version) {
        case 18: return kSlot18;
        case 19: return kSlot19;
        // UNSET(-1) / 30 (folded onto 3.1+Legacy) / 31 / unknown ->
        // 3.1, mirroring the historical dispatcher.
        default: return kSlot31;
        }
    }

    static const char *slotSuffix(int slot) {
        switch (slot) {
        case kSlot18: return "18";
        case kSlot19: return "19";
        default:      return "31";
        }
    }

    // Mint (or check out) a fresh instance. Fallback chain: the
    // requested slot, then 31 -> 19 -> 18 skipping the requested one.
    // Returns the binding, or null when no fresh instance exists.
    void *acquire(int requestedVersion) {
        if (active_.binding) {
            logf("acquire while a session is active");
            return nullptr;
        }
        ops_.saveSigactions(ops_.user);

        const int requested = slotForVersion(requestedVersion);
        const int chain[4] = {requested, kSlot31, kSlot19, kSlot18};
        for (int i = 0; i < 4; ++i) {
            if (i > 0 && chain[i] == requested)
                continue;
            if (acquireSlot(chain[i])) {
                if (chain[i] != requested)
                    logf("requested island unavailable, fell back to %s",
                         slotSuffix(chain[i]));
                return active_.binding;
            }
        }

        ops_.restoreSigactions(ops_.user);
        logf("no fresh Ruby instance available");
        return nullptr;
    }

    void *currentBinding() const { return active_.binding; }

    // Ruby code is about to run: failures past this point leave the
    // island in an unknown state (see retireIfUnexecuted).
    void markExecuting() { active_.executed = true; }

    // The VM quiesce failed; island threads may be alive. Retire
    // must leave the instance checked out.
    void poison() { active_.poisoned = true; }

    bool hasStuckInstance() const { return active_.binding != nullptr; }

    void retire() {
        if (active_.slot < 0)
            return;

        // Ruby's handlers must not outlive the image they live in.
        // Restores the host's fatal-report handlers as a side effect.
        ops_.restoreSigactions(ops_.user);

        if (active_.poisoned) {
            // dlclose, a segment reset, or a zone destroy would rip
            // code and memory out from under possibly-live island
            // threads. Leave the instance checked out; capability
            // then reports DIRTY and the host asks for a restart.
            logf("instance poisoned (quiesce failed); left checked out");
            return;
        }

        // Return the retired VM's entire allocation footprint (heap
        // remainder, pthread keys, leftover GC page mappings) while
        // the island is quiesced and still mapped.
        ops_.reclaimAllocations(ops_.user);

        SlotState &slot = slots_[active_.slot];
        if (active_.handle) {
            ops_.closeImage(ops_.user, active_.handle);
            if (active_.isCanonical) {
                if (ops_.imageResident(ops_.user, slot.dylibPath.c_str())) {
                    slot.canonicalResident = true;
                    // Factory-reset in place: restoring the
                    // pre-ruby_init segment snapshot makes the
                    // resident image a legal host for the next
                    // session's ruby_init.
                    slot.canonicalPristine =
                        slot.snapshotValid &&
                        ops_.restoreSnapshot(ops_.user, active_.slot);
                    logf(slot.canonicalPristine
                             ? "island %s did not unload; segments reset in place"
                             : "island %s did not unload and has no valid "
                               "snapshot; future sessions use copy-and-load",
                         slotSuffix(active_.slot));
                } else {
                    // Genuine unload: the old snapshot's addresses
                    // are stale; the next load recaptures.
                    slot.canonicalResident = false;
                    slot.canonicalPristine = false;
                    slot.snapshotValid = false;
                    ops_.discardSnapshot(ops_.user, active_.slot);
                    logf("island %s unloaded cleanly", slotSuffix(active_.slot));
                }
            }
        }

        active_ = ActiveState();
    }

    // Retire only when execute() never started: the instance is
    // still factory-fresh (ruby_init never ran), so pre-Ruby engine
    // failures don't cost the process its session loop. A static
    // island is even still virgin: un-mark it.
    void retireIfUnexecuted() {
        if (active_.slot < 0 || active_.executed)
            return;
        if (!active_.handle)
            slots_[active_.slot].staticUsed = false;
        retire();
    }

    // What a session for `version` would get right now.
    // `engineTerminated` disambiguates a checked-out instance: on a
    // live engine the query is about the NEXT session ("Quit and
    // play" asks mid-teardown) and the per-slot evaluation already
    // predicts the post-retire answer; after termination it means
    // the RGSS thread crashed or poisoned past retire, so nothing
    // can run.
    int capability(int version, bool engineTerminated) {
        if (active_.binding && engineTerminated)
            return kCapDirty;

        const int requested = slotForVersion(version);
        const int chain[4] = {requested, kSlot31, kSlot19, kSlot18};
        for (int i = 0; i < 4; ++i) {
            if (i > 0 && chain[i] == requested)
                continue;
            SlotState &slot = slots_[chain[i]];
            resolveDylib(chain[i]);
            if (slot.dylibPresent)
                return kCapFresh;
            if (ops_.staticBinding(ops_.user, chain[i]))
                return slot.staticUsed ? kCapDirty : kCapFresh;
        }
        return kCapUnavailable;
    }

    const char *diagnostics() const {
        return diagPublished_.load(std::memory_order_acquire);
    }

    // Test/introspection accessors (also used by the real layer's
    // debug logging).
    int activeSlot() const { return active_.slot; }
    bool activeIsCanonical() const { return active_.isCanonical; }
    int generation(int slot) const { return slots_[slot].generation; }
    bool canonicalResident(int slot) const { return slots_[slot].canonicalResident; }
    bool canonicalPristine(int slot) const { return slots_[slot].canonicalPristine; }
    bool snapshotValid(int slot) const { return slots_[slot].snapshotValid; }
    bool staticUsed(int slot) const { return slots_[slot].staticUsed; }

private:
    struct SlotState {
        bool staticUsed = false;
        bool dylibChecked = false;
        bool dylibPresent = false;
        std::string dylibPath;
        int generation = 0;
        bool canonicalResident = false;
        bool canonicalPristine = false;
        bool snapshotValid = false;
    };

    struct ActiveState {
        int slot = -1;
        void *handle = nullptr; // null for the static fallback
        void *binding = nullptr;
        bool isCanonical = false;
        bool executed = false;
        bool poisoned = false;
    };

    void resolveDylib(int slotIdx) {
        SlotState &slot = slots_[slotIdx];
        if (slot.dylibChecked)
            return;
        slot.dylibChecked = true;
        std::string path;
        if (ops_.resolveDylibPath(ops_.user, slotIdx, &path)) {
            slot.dylibPath = path;
            slot.dylibPresent = true;
        }
    }

    bool acquireSlot(int slotIdx) {
        SlotState &slot = slots_[slotIdx];
        resolveDylib(slotIdx);

        if (slot.dylibPresent) {
            const char *mechanism =
                !slot.canonicalResident ? "canonical"
                : slot.canonicalPristine ? "reset-in-place"
                                         : "copy-and-load";
            void *handle = nullptr;
            void *binding = nullptr;
            bool isCanonical = false;

            if (!slot.canonicalResident || slot.canonicalPristine) {
                handle = ops_.openImage(ops_.user, slotIdx,
                                        slot.dylibPath.c_str());
                if (!handle)
                    return false;
                binding = ops_.resolveBinding(ops_.user, handle, slotIdx);
                if (!binding) {
                    ops_.closeImage(ops_.user, handle);
                    return false;
                }
                // Snapshot the fresh image before any Ruby code
                // dirties it. A reused (reset) resident image needs
                // no recapture: its current bytes ARE the snapshot
                // that was just restored.
                if (!slot.snapshotValid)
                    slot.snapshotValid =
                        ops_.captureSnapshot(ops_.user, slotIdx, binding);
                slot.canonicalPristine = false; // in use -> dirty
                isCanonical = true;
            } else {
                handle = ops_.openImageCopy(ops_.user, slotIdx,
                                            slot.dylibPath.c_str(),
                                            slot.generation);
                if (!handle)
                    return false;
                binding = ops_.resolveBinding(ops_.user, handle, slotIdx);
                if (!binding) {
                    ops_.closeImage(ops_.user, handle);
                    return false;
                }
                isCanonical = false;
            }

            slot.generation++;
            active_.slot = slotIdx;
            active_.handle = handle;
            active_.binding = binding;
            active_.isCanonical = isCanonical;
            active_.executed = false;
            active_.poisoned = false;
            publishf("island %s #%d (%s)", slotSuffix(slotIdx),
                     slot.generation, mechanism);
            return true;
        }

        // Static fallback: the island is linked into the executable.
        // Its globals exist once per process, so exactly one session.
        void *binding = ops_.staticBinding(ops_.user, slotIdx);
        if (!binding || slot.staticUsed)
            return false;
        slot.staticUsed = true;
        active_.slot = slotIdx;
        active_.handle = nullptr;
        active_.binding = binding;
        active_.isCanonical = false;
        active_.executed = false;
        active_.poisoned = false;
        publishf("island %s #1 (static, single-shot)", slotSuffix(slotIdx));
        return true;
    }

    void logf(const char *fmt, ...) __attribute__((format(printf, 2, 3))) {
        char buf[192];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        ops_.log(ops_.user, buf);
    }

    // Diagnostics double-buffer: the writer fills the inactive
    // buffer and atomically publishes it, so a lock-free reader
    // always sees a fully NUL-terminated string.
    void publish(const char *text) {
        snprintf(diagBufs_[diagWriteIdx_], sizeof(diagBufs_[0]), "%s", text);
        diagPublished_.store(diagBufs_[diagWriteIdx_],
                             std::memory_order_release);
        diagWriteIdx_ ^= 1;
    }

    void publishf(const char *fmt, ...) __attribute__((format(printf, 2, 3))) {
        char buf[128];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        publish(buf);
        ops_.log(ops_.user, buf);
    }

    IslandOps ops_;
    SlotState slots_[kSlotCount];
    ActiveState active_;
    char diagBufs_[2][128] = {"", ""};
    std::atomic<const char *> diagPublished_{diagBufs_[0]};
    int diagWriteIdx_ = 1;
};

} // namespace mkxpi

#endif // MKXPZ_ISLAND_STATE_H
