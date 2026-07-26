// island_state_test.cpp - executed unit tests for the Ruby instance
// manager's state machine (src/island_state.h).
//
// The machine decides which freshness mechanism every game session
// gets (canonical dlopen / reset-in-place / copy-and-load / static
// single-shot) and how acquire, retire, poison, crash and capability
// interact. These tests drive it through every lifecycle path with a
// fake ops layer that records call order, so regressions in the
// sequencing contracts (sigactions bracket the session, reclaim runs
// before close, canary only on canonical retires, ...) fail loudly.
//
// Build + run: tests/run-tests.sh (plain C++17, no OS or engine
// dependencies - runs on any host).

#include "../src/island_state.h"

#include <cstdio>
#include <string>
#include <vector>

using mkxpi::IslandStateMachine;
using mkxpi::IslandOps;
using mkxpi::MapRange;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond)                                                          \
    do {                                                                     \
        ++g_checks;                                                          \
        if (!(cond)) {                                                       \
            ++g_failures;                                                    \
            std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);      \
        }                                                                    \
    } while (0)

#define CHECK_EQ_STR(a, b)                                                   \
    do {                                                                     \
        ++g_checks;                                                          \
        if (std::string(a) != std::string(b)) {                              \
            ++g_failures;                                                    \
            std::printf("FAIL %s:%d: \"%s\" != \"%s\"\n", __FILE__,          \
                        __LINE__, std::string(a).c_str(),                    \
                        std::string(b).c_str());                             \
        }                                                                    \
    } while (0)

// ---------------------------------------------------------------------------
// Fake ops: fully scripted OS behavior + an event log for ordering
// assertions.
// ---------------------------------------------------------------------------

struct FakeWorld {
    // Per-slot configuration.
    bool hasDylib[3] = {false, false, false};
    bool staticAvailable[3] = {false, false, false};
    bool openFails[3] = {false, false, false};
    bool bindingFails[3] = {false, false, false};
    bool captureSucceeds = true;
    bool restoreSucceeds = true;
    // Post-dlclose canary answer for the canonical image.
    bool residentAfterClose = true;

    std::vector<std::string> events;
    int sigSaves = 0;
    int sigRestores = 0;
    int reclaims = 0;

    // Distinct non-null pointers per acquire so tests can tell
    // instances apart.
    uintptr_t nextToken = 0x1000;

    void event(const std::string &e) { events.push_back(e); }

    bool sawEvent(const std::string &e) const {
        for (const std::string &x : events)
            if (x == e)
                return true;
        return false;
    }

    int countEvents(const std::string &e) const {
        int n = 0;
        for (const std::string &x : events)
            if (x == e)
                ++n;
        return n;
    }
};

static const char *sfx(int slot) {
    return IslandStateMachine::slotSuffix(slot);
}

static IslandOps makeOps(FakeWorld *w) {
    IslandOps ops;
    ops.user = w;
    ops.openImage = [](void *u, int slot, const char *) -> void * {
        FakeWorld *w = (FakeWorld *)u;
        w->event(std::string("open:") + sfx(slot));
        if (w->openFails[slot])
            return nullptr;
        return (void *)(w->nextToken += 0x10);
    };
    ops.openImageCopy = [](void *u, int slot, const char *,
                           int generation) -> void * {
        FakeWorld *w = (FakeWorld *)u;
        char buf[64];
        std::snprintf(buf, sizeof(buf), "opencopy:%s:gen%d", sfx(slot),
                      generation);
        w->event(buf);
        if (w->openFails[slot])
            return nullptr;
        return (void *)(w->nextToken += 0x10);
    };
    ops.closeImage = [](void *u, void *) {
        ((FakeWorld *)u)->event("close");
    };
    ops.imageResident = [](void *u, const char *) -> bool {
        FakeWorld *w = (FakeWorld *)u;
        w->event("canary");
        return w->residentAfterClose;
    };
    ops.resolveBinding = [](void *u, void *, int slot) -> void * {
        FakeWorld *w = (FakeWorld *)u;
        if (w->bindingFails[slot])
            return nullptr;
        return (void *)(w->nextToken += 0x10);
    };
    ops.staticBinding = [](void *u, int slot) -> void * {
        FakeWorld *w = (FakeWorld *)u;
        if (!w->staticAvailable[slot])
            return nullptr;
        // Stable per-slot pointer: the real static entry returns the
        // same vtable every call.
        return (void *)(uintptr_t)(0x9000 + slot);
    };
    ops.resolveDylibPath = [](void *u, int slot, std::string *out) -> bool {
        FakeWorld *w = (FakeWorld *)u;
        if (!w->hasDylib[slot])
            return false;
        *out = std::string("/fake/RubyIsland") + sfx(slot);
        return true;
    };
    ops.captureSnapshot = [](void *u, int slot, void *) -> bool {
        FakeWorld *w = (FakeWorld *)u;
        w->event(std::string("capture:") + sfx(slot));
        return w->captureSucceeds;
    };
    ops.restoreSnapshot = [](void *u, int slot) -> bool {
        FakeWorld *w = (FakeWorld *)u;
        w->event(std::string("restore:") + sfx(slot));
        return w->restoreSucceeds;
    };
    ops.discardSnapshot = [](void *u, int slot) {
        ((FakeWorld *)u)->event(std::string("discard:") + sfx(slot));
    };
    ops.saveSigactions = [](void *u) {
        FakeWorld *w = (FakeWorld *)u;
        ++w->sigSaves;
        w->event("sigsave");
    };
    ops.restoreSigactions = [](void *u) {
        FakeWorld *w = (FakeWorld *)u;
        ++w->sigRestores;
        w->event("sigrestore");
    };
    ops.reclaimAllocations = [](void *u) {
        FakeWorld *w = (FakeWorld *)u;
        ++w->reclaims;
        w->event("reclaim");
    };
    ops.log = [](void *u, const char *msg) {
        ((FakeWorld *)u)->event(std::string("log:") + msg);
    };
    return ops;
}

static int indexOfEvent(const FakeWorld &w, const std::string &e,
                        int occurrence = 1) {
    int seen = 0;
    for (size_t i = 0; i < w.events.size(); ++i) {
        if (w.events[i] == e && ++seen == occurrence)
            return (int)i;
    }
    return -1;
}

// ---------------------------------------------------------------------------
// Scenarios.
// ---------------------------------------------------------------------------

// A dylib-backed island whose image never unloads but resets in
// place: the expected steady state on iOS. Sessions must cycle
// canonical -> reset-in-place -> reset-in-place... with exactly one
// snapshot capture and no copies.
static void testResetInPlaceSteadyState() {
    FakeWorld w;
    w.hasDylib[mkxpi::kSlot31] = true;
    w.residentAfterClose = true;
    w.restoreSucceeds = true;
    IslandStateMachine m(makeOps(&w));

    // Session 1: canonical.
    void *b1 = m.acquire(31);
    CHECK(b1 != nullptr);
    CHECK(m.currentBinding() == b1);
    CHECK(m.activeIsCanonical());
    CHECK(m.generation(mkxpi::kSlot31) == 1);
    CHECK(m.snapshotValid(mkxpi::kSlot31));
    CHECK_EQ_STR(m.diagnostics(), "island 31 #1 (canonical)");
    CHECK(w.sigSaves == 1);

    m.markExecuting();
    m.retire();
    CHECK(m.currentBinding() == nullptr);
    CHECK(!m.hasStuckInstance());
    CHECK(w.sigRestores == 1);
    CHECK(w.reclaims == 1);
    CHECK(m.canonicalResident(mkxpi::kSlot31));
    CHECK(m.canonicalPristine(mkxpi::kSlot31));
    // Ordering: sigrestore -> reclaim -> close -> canary -> restore.
    CHECK(indexOfEvent(w, "sigrestore") < indexOfEvent(w, "reclaim"));
    CHECK(indexOfEvent(w, "reclaim") < indexOfEvent(w, "close"));
    CHECK(indexOfEvent(w, "close") < indexOfEvent(w, "canary"));
    CHECK(indexOfEvent(w, "canary") < indexOfEvent(w, "restore:31"));

    // Sessions 2..4: reset-in-place, no recapture, no copies.
    for (int session = 2; session <= 4; ++session) {
        void *b = m.acquire(31);
        CHECK(b != nullptr);
        CHECK(m.activeIsCanonical());
        char expect[64];
        std::snprintf(expect, sizeof(expect),
                      "island 31 #%d (reset-in-place)", session);
        CHECK_EQ_STR(m.diagnostics(), expect);
        CHECK(!m.canonicalPristine(mkxpi::kSlot31)); // in use -> dirty
        m.markExecuting();
        m.retire();
        CHECK(m.canonicalPristine(mkxpi::kSlot31));
    }
    CHECK(w.countEvents("capture:31") == 1);
    CHECK(w.countEvents("restore:31") == 4);
    CHECK(w.countEvents("opencopy:31:gen1") == 0);
    CHECK(w.sigSaves == 4);
    CHECK(w.sigRestores == 4);
    CHECK(w.reclaims == 4);
}

// A dylib island that genuinely unloads: every session is canonical
// with a fresh capture; the stale snapshot must be discarded.
static void testUnloadSteadyState() {
    FakeWorld w;
    w.hasDylib[mkxpi::kSlot31] = true;
    w.residentAfterClose = false;
    IslandStateMachine m(makeOps(&w));

    for (int session = 1; session <= 3; ++session) {
        void *b = m.acquire(31);
        CHECK(b != nullptr);
        char expect[64];
        std::snprintf(expect, sizeof(expect), "island 31 #%d (canonical)",
                      session);
        CHECK_EQ_STR(m.diagnostics(), expect);
        m.markExecuting();
        m.retire();
        CHECK(!m.canonicalResident(mkxpi::kSlot31));
        CHECK(!m.snapshotValid(mkxpi::kSlot31));
    }
    CHECK(w.countEvents("capture:31") == 3);
    CHECK(w.countEvents("discard:31") == 3);
    CHECK(w.countEvents("restore:31") == 0);
}

// Snapshot capture fails and the image never unloads: sessions
// degrade to copy-and-load. Copy retires must not probe the canary
// or touch canonical state, and generations keep counting.
static void testCopyAndLoadFallback() {
    FakeWorld w;
    w.hasDylib[mkxpi::kSlot31] = true;
    w.residentAfterClose = true;
    w.captureSucceeds = false;
    IslandStateMachine m(makeOps(&w));

    void *b1 = m.acquire(31);
    CHECK(b1 != nullptr);
    CHECK(!m.snapshotValid(mkxpi::kSlot31));
    m.markExecuting();
    m.retire();
    // No valid snapshot: restore must not even be attempted.
    CHECK(w.countEvents("restore:31") == 0);
    CHECK(m.canonicalResident(mkxpi::kSlot31));
    CHECK(!m.canonicalPristine(mkxpi::kSlot31));

    void *b2 = m.acquire(31);
    CHECK(b2 != nullptr);
    CHECK(!m.activeIsCanonical());
    CHECK_EQ_STR(m.diagnostics(), "island 31 #2 (copy-and-load)");
    CHECK(w.countEvents("opencopy:31:gen1") == 1);
    // Copies are never snapshot: only the resident canonical image
    // is a reset-in-place candidate. (One failed capture from the
    // canonical session, nothing after.)
    CHECK(w.countEvents("capture:31") == 1);

    int canaries = w.countEvents("canary");
    m.markExecuting();
    m.retire();
    // Copy retire: close yes, canary no, canonical state untouched.
    CHECK(w.countEvents("canary") == canaries);
    CHECK(m.canonicalResident(mkxpi::kSlot31));

    void *b3 = m.acquire(31);
    CHECK(b3 != nullptr);
    CHECK_EQ_STR(m.diagnostics(), "island 31 #3 (copy-and-load)");
    CHECK(w.countEvents("opencopy:31:gen2") == 1);
}

// Poisoned quiesce: retire must leave the instance checked out and
// must NOT reclaim, close, canary, or reset - the island may still
// have live threads. Capability then blocks everything once the
// engine reports terminated.
static void testPoisonLeavesInstanceCheckedOut() {
    FakeWorld w;
    w.hasDylib[mkxpi::kSlot31] = true;
    IslandStateMachine m(makeOps(&w));

    void *b = m.acquire(31);
    CHECK(b != nullptr);
    m.markExecuting();
    m.poison();
    m.retire();

    CHECK(m.hasStuckInstance());
    CHECK(m.currentBinding() == b);
    CHECK(w.reclaims == 0);
    CHECK(w.countEvents("close") == 0);
    CHECK(w.countEvents("canary") == 0);
    CHECK(w.countEvents("restore:31") == 0);
    // Sigactions still restored: the host's crash handlers must be
    // back even on the poisoned path (image stays resident).
    CHECK(w.sigRestores == 1);

    // Crashed/poisoned past retire + engine terminated: everything
    // is blocked, for every version.
    CHECK(m.capability(31, true) == mkxpi::kCapDirty);
    CHECK(m.capability(18, true) == mkxpi::kCapDirty);
    // While the engine still runs, capability predicts the next
    // session (the "Quit and play" query): the dylib can mint fresh.
    CHECK(m.capability(31, false) == mkxpi::kCapFresh);

    // A second retire stays a no-op; the instance remains stuck.
    m.retire();
    CHECK(m.hasStuckInstance());
}

// Pre-execute failures retire a still-pristine instance; a static
// island is even un-marked as used so the launch stays available.
static void testRetireIfUnexecuted() {
    // Dylib case.
    {
        FakeWorld w;
        w.hasDylib[mkxpi::kSlot31] = true;
        w.residentAfterClose = true;
        IslandStateMachine m(makeOps(&w));
        CHECK(m.acquire(31) != nullptr);
        m.retireIfUnexecuted();
        CHECK(!m.hasStuckInstance());
        CHECK(m.capability(31, true) == mkxpi::kCapFresh);
        // After executing, retireIfUnexecuted must be a no-op.
        CHECK(m.acquire(31) != nullptr);
        m.markExecuting();
        m.retireIfUnexecuted();
        CHECK(m.hasStuckInstance());
        m.retire();
        CHECK(!m.hasStuckInstance());
    }
    // Static case: the virgin island is returned to the pool.
    {
        FakeWorld w;
        w.staticAvailable[mkxpi::kSlot31] = true;
        IslandStateMachine m(makeOps(&w));
        CHECK(m.acquire(31) != nullptr);
        CHECK(m.staticUsed(mkxpi::kSlot31));
        m.retireIfUnexecuted();
        CHECK(!m.staticUsed(mkxpi::kSlot31));
        CHECK(m.capability(31, false) == mkxpi::kCapFresh);
        // And the session can actually start again.
        CHECK(m.acquire(31) != nullptr);
    }
}

// Static islands are single-shot: capability flips FRESH -> DIRTY,
// and a second acquire finds nothing (all fallbacks exhausted).
static void testStaticSingleShot() {
    FakeWorld w;
    w.staticAvailable[mkxpi::kSlot31] = true;
    IslandStateMachine m(makeOps(&w));

    CHECK(m.capability(31, false) == mkxpi::kCapFresh);
    void *b = m.acquire(31);
    CHECK(b != nullptr);
    CHECK_EQ_STR(m.diagnostics(), "island 31 #1 (static, single-shot)");
    m.markExecuting();
    m.retire();
    CHECK(w.countEvents("close") == 0); // nothing to dlclose
    CHECK(m.capability(31, false) == mkxpi::kCapDirty);
    CHECK(m.acquire(31) == nullptr);
    // The failed acquire must restore sigactions (it saved them).
    CHECK(w.sigSaves == w.sigRestores);
}

// Cross-version static switching: 1.8 after 3.1 works, and each
// version is independently single-shot.
static void testStaticCrossVersion() {
    FakeWorld w;
    w.staticAvailable[mkxpi::kSlot18] = true;
    w.staticAvailable[mkxpi::kSlot31] = true;
    IslandStateMachine m(makeOps(&w));

    CHECK(m.acquire(31) != nullptr);
    m.markExecuting();
    m.retire();

    CHECK(m.capability(18, false) == mkxpi::kCapFresh);
    void *b = m.acquire(18);
    CHECK(b != nullptr);
    CHECK_EQ_STR(m.diagnostics(), "island 18 #1 (static, single-shot)");
    m.markExecuting();
    m.retire();

    CHECK(m.capability(18, false) == mkxpi::kCapDirty);
    CHECK(m.capability(31, false) == mkxpi::kCapDirty);
}

// Version routing: UNSET(-1), 30 and unknown values fold onto the
// 3.1 slot, for acquire and capability alike.
static void testVersionRouting() {
    FakeWorld w;
    w.hasDylib[mkxpi::kSlot31] = true;
    IslandStateMachine m(makeOps(&w));

    CHECK(m.capability(-1, false) == mkxpi::kCapFresh);
    CHECK(m.capability(30, false) == mkxpi::kCapFresh);
    CHECK(m.capability(9999, false) == mkxpi::kCapFresh);

    void *b = m.acquire(30);
    CHECK(b != nullptr);
    CHECK(m.activeSlot() == mkxpi::kSlot31);
}

// Fallback chain: a requested version with no island falls through
// to the newest available one, exactly once, with the fallback
// logged.
static void testFallbackChain() {
    FakeWorld w;
    w.hasDylib[mkxpi::kSlot19] = true;
    IslandStateMachine m(makeOps(&w));

    void *b = m.acquire(18); // no 18, no 31 -> 19
    CHECK(b != nullptr);
    CHECK(m.activeSlot() == mkxpi::kSlot19);
    CHECK(w.sawEvent("log:requested island unavailable, fell back to 19"));
    // Requested-slot dedup: 18 must not be probed twice.
    CHECK(m.capability(18, false) == mkxpi::kCapFresh); // via 19

    // Newest-first: with BOTH 19 and 31 available, a request for a
    // missing 18 must land on 31, not 19 - script-engine features
    // stay maximal (the historical dispatcher's contract).
    FakeWorld w2;
    w2.hasDylib[mkxpi::kSlot19] = true;
    w2.hasDylib[mkxpi::kSlot31] = true;
    IslandStateMachine m2(makeOps(&w2));
    void *b2 = m2.acquire(18);
    CHECK(b2 != nullptr);
    CHECK(m2.activeSlot() == mkxpi::kSlot31);
}

// Loader failures fall through the chain instead of aborting the
// acquire: a broken dylib open tries the next island; a broken entry
// resolve closes the half-open image first.
static void testLoaderFailureFallsThrough() {
    FakeWorld w;
    w.hasDylib[mkxpi::kSlot31] = true;
    w.hasDylib[mkxpi::kSlot19] = true;
    w.openFails[mkxpi::kSlot31] = true;
    IslandStateMachine m(makeOps(&w));

    void *b = m.acquire(31);
    CHECK(b != nullptr);
    CHECK(m.activeSlot() == mkxpi::kSlot19);

    m.markExecuting();
    m.retire();

    // Entry-resolve failure: image must be closed before falling
    // through.
    FakeWorld w2;
    w2.hasDylib[mkxpi::kSlot31] = true;
    w2.staticAvailable[mkxpi::kSlot18] = true;
    w2.bindingFails[mkxpi::kSlot31] = true;
    IslandStateMachine m2(makeOps(&w2));
    void *b2 = m2.acquire(31);
    CHECK(b2 != nullptr);
    CHECK(m2.activeSlot() == mkxpi::kSlot18);
    CHECK(indexOfEvent(w2, "open:31") >= 0);
    CHECK(indexOfEvent(w2, "close") > indexOfEvent(w2, "open:31"));
}

// Nothing available anywhere: acquire fails cleanly (sigactions
// balanced), capability says UNAVAILABLE, retire is a no-op.
static void testNothingAvailable() {
    FakeWorld w;
    IslandStateMachine m(makeOps(&w));

    CHECK(m.capability(31, false) == mkxpi::kCapUnavailable);
    CHECK(m.acquire(31) == nullptr);
    CHECK(w.sigSaves == 1);
    CHECK(w.sigRestores == 1);
    m.retire(); // no-op
    CHECK(w.reclaims == 0);
    CHECK_EQ_STR(m.diagnostics(), "no session yet");
}

// Acquire while a session is active must fail without side effects.
static void testAcquireWhileActive() {
    FakeWorld w;
    w.hasDylib[mkxpi::kSlot31] = true;
    IslandStateMachine m(makeOps(&w));

    void *b = m.acquire(31);
    CHECK(b != nullptr);
    int saves = w.sigSaves;
    CHECK(m.acquire(31) == nullptr);
    CHECK(w.sigSaves == saves); // no second save
    CHECK(m.currentBinding() == b);
}

// The diagnostics double-buffer must alternate storage so a reader
// holding the previous pointer never sees it half-overwritten.
static void testDiagnosticsDoubleBuffer() {
    FakeWorld w;
    w.hasDylib[mkxpi::kSlot31] = true;
    w.residentAfterClose = true;
    IslandStateMachine m(makeOps(&w));

    CHECK(m.acquire(31) != nullptr);
    const char *p1 = m.diagnostics();
    std::string s1 = p1;
    m.markExecuting();
    m.retire();
    CHECK(m.acquire(31) != nullptr);
    const char *p2 = m.diagnostics();
    CHECK(p1 != p2);            // alternated buffers
    CHECK_EQ_STR(p1, s1);       // old buffer still intact
    CHECK_EQ_STR(p2, "island 31 #2 (reset-in-place)");
}

// replayMappings: faithful interval replay for the mmap reclaim.
// The reclaimer munmaps whatever this returns, so an over-report
// here is a wild munmap of someone else's memory - the tests bias
// toward proving NOTHING extra survives.
static void testReplayMappings() {
    using mkxpi::MapEvent;
    uint64_t clock = 0;
    auto ev = [&clock](uint64_t a, uint64_t l, bool unmap) {
        MapEvent e;
        e.addr = a;
        e.len = l;
        e.time = ++clock;
        e.unmap = unmap;
        return e;
    };

    // Ruby 3.1's GC page pattern: mmap oversized, trim the
    // misaligned head and tail with partial munmaps, later free the
    // aligned page with a page-sized munmap that matches NO recorded
    // map range. Everything must be gone.
    {
        std::vector<MapEvent> events = {
            ev(0x10000, 0x8000, false),  // map [0x10000, 0x18000)
            ev(0x10000, 0x2000, true),   // trim head
            ev(0x16000, 0x2000, true),   // trim tail -> page [0x12000, 0x16000)
            ev(0x12000, 0x4000, true),   // free the aligned page
        };
        CHECK(mkxpi::replayMappings(events).empty());
    }

    // Same pattern but the page stays live: exactly the aligned
    // middle survives - not the original full range.
    {
        std::vector<MapEvent> events = {
            ev(0x10000, 0x8000, false),
            ev(0x10000, 0x2000, true),
            ev(0x16000, 0x2000, true),
        };
        auto left = mkxpi::replayMappings(events);
        CHECK(left.size() == 1);
        CHECK(left[0].addr == 0x12000);
        CHECK(left[0].len == 0x4000);
    }

    // Address reuse across map/unmap cycles: the kernel hands the
    // same range out again; only the LIVE generation survives.
    {
        std::vector<MapEvent> events = {
            ev(0x1000, 0x4000, false),
            ev(0x1000, 0x4000, true),
            ev(0x1000, 0x4000, false), // reuse, still live
        };
        auto left = mkxpi::replayMappings(events);
        CHECK(left.size() == 1);
        CHECK(left[0].addr == 0x1000);
        CHECK(left[0].len == 0x4000);
    }

    // Reuse then freed again: nothing survives.
    {
        std::vector<MapEvent> events = {
            ev(0x1000, 0x4000, false),
            ev(0x1000, 0x4000, true),
            ev(0x1000, 0x4000, false),
            ev(0x1000, 0x4000, true),
        };
        CHECK(mkxpi::replayMappings(events).empty());
    }

    // Enumeration order is arbitrary: the same history shuffled must
    // replay identically (timestamps recover the sequence).
    {
        std::vector<MapEvent> events = {
            ev(0x1000, 0x4000, false), // t1 map
            ev(0x1000, 0x4000, true),  // t2 unmap
            ev(0x1000, 0x4000, false), // t3 map again -> live
        };
        std::swap(events[0], events[2]);
        auto left = mkxpi::replayMappings(events);
        CHECK(left.size() == 1);
    }

    // Order-sensitivity proof: [map, unmap] shuffled to [unmap, map]
    // must STILL replay as map-then-unmap (empty). An implementation
    // that trusts enumeration order would resurrect the mapping.
    {
        std::vector<MapEvent> events = {
            ev(0x1000, 0x4000, false), // t1 map
            ev(0x1000, 0x4000, true),  // t2 unmap -> empty history
        };
        std::swap(events[0], events[1]); // enumerator saw unmap first
        CHECK(mkxpi::replayMappings(events).empty());
    }

    // A partial unmap splits a live range in two.
    {
        std::vector<MapEvent> events = {
            ev(0x1000, 0x9000, false),  // [0x1000, 0xA000)
            ev(0x4000, 0x2000, true),   // hole [0x4000, 0x6000)
        };
        auto left = mkxpi::replayMappings(events);
        CHECK(left.size() == 2);
        CHECK(left[0].addr == 0x1000);
        CHECK(left[0].len == 0x3000);
        CHECK(left[1].addr == 0x6000);
        CHECK(left[1].len == 0x4000);
    }

    // An unmap spanning several live ranges clears them all.
    {
        std::vector<MapEvent> events = {
            ev(0x1000, 0x1000, false),
            ev(0x3000, 0x1000, false),
            ev(0x5000, 0x1000, false),
            ev(0x0000, 0x7000, true),
        };
        CHECK(mkxpi::replayMappings(events).empty());
    }

    // An unmap of something never recorded is a no-op.
    {
        std::vector<MapEvent> events = {ev(0x1000, 0x1000, true)};
        CHECK(mkxpi::replayMappings(events).empty());
    }

    // A new map implicitly replaces what it overlaps (no
    // double-count of the overlapped bytes).
    {
        std::vector<MapEvent> events = {
            ev(0x1000, 0x4000, false),
            ev(0x2000, 0x1000, false), // overlays the middle
            ev(0x1000, 0x4000, true),  // unmap the whole range
        };
        CHECK(mkxpi::replayMappings(events).empty());
    }

    // Zero-length events are ignored.
    {
        std::vector<MapEvent> events = {ev(0x1000, 0, false)};
        CHECK(mkxpi::replayMappings(events).empty());
    }

    CHECK(mkxpi::replayMappings({}).empty());
}

// liveKeys: creates minus deletes per key number. Re-deleting a key
// the VM released itself could destroy a foreign library's live TLS
// key (Darwin reuses slots), so deleted keys must drop out.
static void testLiveKeys() {
    // Simple: created, never deleted -> live.
    CHECK(mkxpi::liveKeys({7}, {}).size() == 1);
    // Created and deleted -> NOT live.
    CHECK(mkxpi::liveKeys({7}, {7}).empty());
    // Slot reuse within a session: create K, delete K, create K
    // again -> exactly one delete owed.
    {
        auto live = mkxpi::liveKeys({7, 7}, {7});
        CHECK(live.size() == 1);
        CHECK(live[0] == 7);
    }
    // Multiple distinct keys, one deleted.
    {
        auto live = mkxpi::liveKeys({3, 5, 9}, {5});
        CHECK(live.size() == 2);
        CHECK(live[0] == 3);
        CHECK(live[1] == 9);
    }
    // A stray delete with no create must not go negative into a
    // later create of the same number... it does consume it: the VM
    // deleting a key it got from elsewhere is out of scope, but the
    // net computation must simply never produce a key with net <= 0.
    CHECK(mkxpi::liveKeys({}, {4}).empty());
    CHECK(mkxpi::liveKeys({}, {}).empty());
}

// The full mixed-corpus story: a 3.1 PE fork, then a 1.8 vintage
// game, then 3.1 again, on dylib islands with reset-in-place. This
// is the user-visible promise ("switch games forever") end to end.
static void testMixedCorpusCycle() {
    FakeWorld w;
    w.hasDylib[mkxpi::kSlot31] = true;
    w.hasDylib[mkxpi::kSlot18] = true;
    w.residentAfterClose = true;
    IslandStateMachine m(makeOps(&w));

    for (int cycle = 0; cycle < 5; ++cycle) {
        CHECK(m.capability(31, false) == mkxpi::kCapFresh);
        CHECK(m.acquire(31) != nullptr);
        m.markExecuting();
        m.retire();
        CHECK(!m.hasStuckInstance());

        CHECK(m.capability(18, false) == mkxpi::kCapFresh);
        CHECK(m.acquire(18) != nullptr);
        m.markExecuting();
        m.retire();
        CHECK(!m.hasStuckInstance());
    }
    CHECK(m.generation(mkxpi::kSlot31) == 5);
    CHECK(m.generation(mkxpi::kSlot18) == 5);
    // One capture per island; every later session reset in place.
    CHECK(w.countEvents("capture:31") == 1);
    CHECK(w.countEvents("capture:18") == 1);
    CHECK(w.reclaims == 10);
    CHECK(w.sigSaves == 10);
    CHECK(w.sigRestores == 10);
}

int runAll() {
    testResetInPlaceSteadyState();
    testUnloadSteadyState();
    testCopyAndLoadFallback();
    testPoisonLeavesInstanceCheckedOut();
    testRetireIfUnexecuted();
    testStaticSingleShot();
    testStaticCrossVersion();
    testVersionRouting();
    testFallbackChain();
    testLoaderFailureFallsThrough();
    testNothingAvailable();
    testAcquireWhileActive();
    testDiagnosticsDoubleBuffer();
    testReplayMappings();
    testLiveKeys();
    testMixedCorpusCycle();

    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}

int main() {
    return runAll();
}
