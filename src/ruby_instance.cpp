// ruby_instance.cpp - per-session Ruby VM instance manager.
// See ruby_instance.h for the design rationale.

#include "ruby_instance.h"

#if MKXPZ_MOBILE

#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <copyfile.h>
#endif

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

#include "util/debugwriter.h"

// Static island entry points (merged.o). On builds where the project
// pre-build script stubbed a version out, the entry returns NULL.
// Declared here instead of via binding.h to avoid an include cycle
// (binding.h's iOS branch includes ruby_instance.h).
extern "C" ScriptBinding *mkxp_get_script_binding_18(void);
extern "C" ScriptBinding *mkxp_get_script_binding_19(void);
extern "C" ScriptBinding *mkxp_get_script_binding_31(void);

namespace {

struct IslandSlot {
    const char *suffix;                  // "18" / "19" / "31"
    ScriptBinding *(*staticEntry)(void);

    // Static-fallback bookkeeping: one session per process.
    bool staticUsed = false;

    // Dylib island state.
    bool dylibChecked = false;
    bool dylibPresent = false;
    std::string dylibPath;
    int generation = 0;         // fresh instances minted so far
    // The canonical image survived a dlclose (RTLD_NOLOAD canary saw
    // it still resident). Its statics are dirty forever; later
    // sessions must route through copy-and-load.
    bool canonicalResident = false;
};

IslandSlot s_slots[3] = {
    {"18", mkxp_get_script_binding_18},
    {"19", mkxp_get_script_binding_19},
    {"31", mkxp_get_script_binding_31},
};

// Guards all slot state. acquire/retire run on the RGSS thread;
// capability queries come from the host's main thread.
std::mutex s_mutex;

// Active session (write under s_mutex; currentScriptBinding reads
// the binding pointer without it - it's stable for the whole
// acquire..retire window, which brackets every reader).
IslandSlot *s_activeSlot = nullptr;
void *s_activeHandle = nullptr;          // NULL for static fallback
ScriptBinding *s_activeBinding = nullptr;
bool s_activeIsCanonical = false;

// Process sigaction table snapshot, taken at acquire and restored at
// retire. ruby_init installs handlers (SEGV, PIPE, INT, ...) that
// would otherwise point into a retired - possibly unloaded - image.
struct sigaction s_savedSigactions[NSIG];
bool s_sigactionsSaved = false;

IslandSlot *slotFor(MKXPRubyVersion version) {
    switch (version) {
    case MKXP_RUBY_18: return &s_slots[0];
    case MKXP_RUBY_19: return &s_slots[1];
    // UNSET / 30 (folded onto 3.1 + Legacy) / 31 / unknown -> 3.1,
    // mirroring the historical getActiveScriptBinding dispatch.
    default:           return &s_slots[2];
    }
}

void resolveDylib(IslandSlot &slot) {
    if (slot.dylibChecked)
        return;
    slot.dylibChecked = true;

#ifdef __APPLE__
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle)
        return;
    CFURLRef fwURL = CFBundleCopyPrivateFrameworksURL(bundle);
    if (!fwURL)
        return;
    char fwPath[1024] = {0};
    bool ok = CFURLGetFileSystemRepresentation(
        fwURL, true, (UInt8 *)fwPath, sizeof(fwPath));
    CFRelease(fwURL);
    if (!ok)
        return;

    std::string path = std::string(fwPath) + "/RubyIsland" + slot.suffix +
                       ".framework/RubyIsland" + slot.suffix;
    struct stat st;
    if (stat(path.c_str(), &st) == 0) {
        slot.dylibPath = path;
        slot.dylibPresent = true;
    }
#endif
}

ScriptBinding *loadEntry(void *handle, const IslandSlot &slot) {
    std::string sym = std::string("mkxp_get_script_binding_") + slot.suffix;
    typedef ScriptBinding *(*EntryFn)(void);
    EntryFn entry = (EntryFn)dlsym(handle, sym.c_str());
    if (!entry) {
        Debug() << "ruby_instance: dlsym" << sym << "failed:" << dlerror();
        return nullptr;
    }
    return entry();
}

// Mint a fresh image for the slot. Returns the dlopen handle and
// fills *outBinding / *outIsCanonical. Caller holds s_mutex.
void *openFreshImage(IslandSlot &slot, ScriptBinding **outBinding,
                     bool *outIsCanonical) {
    // Canonical path first: after a verified unload (or before the
    // first load) its statics are pristine.
    if (!slot.canonicalResident) {
        void *handle = dlopen(slot.dylibPath.c_str(), RTLD_LOCAL | RTLD_NOW);
        if (!handle) {
            Debug() << "ruby_instance: dlopen" << slot.dylibPath
                    << "failed:" << dlerror();
            return nullptr;
        }
        ScriptBinding *binding = loadEntry(handle, slot);
        if (!binding) {
            dlclose(handle);
            return nullptr;
        }
        *outBinding = binding;
        *outIsCanonical = true;
        return handle;
    }

    // Copy-and-load: the canonical image is resident with dirty
    // statics. A byte-identical copy at a unique path is a distinct
    // dyld image with fresh statics. The copy keeps the original's
    // embedded code signature (content-hashed, path-independent),
    // and we unlink it right after load - the mapping survives, so
    // there is no disk accumulation across sessions.
#ifdef __APPLE__
    const char *tmpDir = getenv("TMPDIR");
    if (!tmpDir || !tmpDir[0])
        tmpDir = "/tmp";
    char copyPath[1024];
    snprintf(copyPath, sizeof(copyPath), "%s/RubyIsland%s.gen%d.dylib",
             tmpDir, slot.suffix, slot.generation);
    unlink(copyPath);
    if (copyfile(slot.dylibPath.c_str(), copyPath, nullptr, COPYFILE_ALL) != 0) {
        Debug() << "ruby_instance: copyfile to" << copyPath << "failed";
        return nullptr;
    }
    void *handle = dlopen(copyPath, RTLD_LOCAL | RTLD_NOW);
    unlink(copyPath);
    if (!handle) {
        Debug() << "ruby_instance: dlopen (copy)" << copyPath
                << "failed:" << dlerror();
        return nullptr;
    }
    ScriptBinding *binding = loadEntry(handle, slot);
    if (!binding) {
        dlclose(handle);
        return nullptr;
    }
    *outBinding = binding;
    *outIsCanonical = false;
    return handle;
#else
    return nullptr;
#endif
}

// Try to make `slot` the active session's island. Caller holds
// s_mutex.
bool acquireSlot(IslandSlot &slot) {
    resolveDylib(slot);

    if (slot.dylibPresent) {
        ScriptBinding *binding = nullptr;
        bool isCanonical = false;
        void *handle = openFreshImage(slot, &binding, &isCanonical);
        if (!handle)
            return false;
        slot.generation++;
        s_activeSlot = &slot;
        s_activeHandle = handle;
        s_activeBinding = binding;
        s_activeIsCanonical = isCanonical;
        Debug() << "ruby_instance: island" << slot.suffix << "gen"
                << slot.generation << (isCanonical ? "(canonical)" : "(copy)");
        return true;
    }

    // Static fallback: the island is linked into the executable.
    // Its globals exist once per process, so exactly one session.
    ScriptBinding *binding = slot.staticEntry();
    if (!binding || slot.staticUsed)
        return false;
    slot.staticUsed = true;
    s_activeSlot = &slot;
    s_activeHandle = nullptr;
    s_activeBinding = binding;
    s_activeIsCanonical = false;
    Debug() << "ruby_instance: island" << slot.suffix << "(static, single-shot)";
    return true;
}

void saveSigactions() {
    for (int sig = 1; sig < NSIG; ++sig)
        sigaction(sig, nullptr, &s_savedSigactions[sig]);
    s_sigactionsSaved = true;
}

void restoreSigactions() {
    if (!s_sigactionsSaved)
        return;
    for (int sig = 1; sig < NSIG; ++sig) {
        if (sig == SIGKILL || sig == SIGSTOP)
            continue;
        sigaction(sig, &s_savedSigactions[sig], nullptr);
    }
    s_sigactionsSaved = false;
}

} // namespace

extern "C" {

ScriptBinding *mkxpi_acquireRubyInstance(MKXPRubyVersion requested) {
    std::lock_guard<std::mutex> lock(s_mutex);

    if (s_activeBinding) {
        Debug() << "ruby_instance: acquire while a session is active";
        return nullptr;
    }

    saveSigactions();

    if (acquireSlot(*slotFor(requested)))
        return s_activeBinding;

    // Fallback chain, newest first, mirroring the historical
    // dispatcher: a stubbed or exhausted requested version falls
    // through to whichever island can still mint an instance.
    for (IslandSlot *slot : {&s_slots[2], &s_slots[1], &s_slots[0]}) {
        if (slot == slotFor(requested))
            continue;
        if (acquireSlot(*slot)) {
            Debug() << "ruby_instance: requested island unavailable,"
                    << "fell back to" << slot->suffix;
            return s_activeBinding;
        }
    }

    restoreSigactions();
    Debug() << "ruby_instance: no fresh Ruby instance available";
    return nullptr;
}

ScriptBinding *mkxpi_currentScriptBinding(void) {
    return s_activeBinding;
}

void mkxpi_retireRubyInstance(void) {
    std::lock_guard<std::mutex> lock(s_mutex);

    if (!s_activeSlot)
        return;

    // Ruby's handlers must not outlive the image they live in.
    // Restores the host's fatal-report handlers as a side effect.
    restoreSigactions();

    IslandSlot &slot = *s_activeSlot;
    if (s_activeHandle) {
        dlclose(s_activeHandle);

        // Unload canary: only a genuinely unloaded canonical image
        // may be reopened for a fresh session. RTLD_NOLOAD returns
        // the existing handle (refcount bumped, balance it) when the
        // image is still resident.
        if (s_activeIsCanonical) {
            void *probe = dlopen(slot.dylibPath.c_str(),
                                 RTLD_LOCAL | RTLD_LAZY | RTLD_NOLOAD);
            if (probe) {
                dlclose(probe);
                if (!slot.canonicalResident)
                    Debug() << "ruby_instance: island" << slot.suffix
                            << "did not unload; future sessions use"
                            << "copy-and-load";
                slot.canonicalResident = true;
            } else {
                slot.canonicalResident = false;
                Debug() << "ruby_instance: island" << slot.suffix
                        << "unloaded cleanly";
            }
        }
    }

    s_activeSlot = nullptr;
    s_activeHandle = nullptr;
    s_activeBinding = nullptr;
    s_activeIsCanonical = false;
}

MKXPSessionCapability mkxpi_sessionCapability(MKXPRubyVersion version) {
    std::lock_guard<std::mutex> lock(s_mutex);

    // A terminated engine with an instance still checked out means
    // the RGSS thread crashed past the retire path. The island's
    // threads and state are unknown; block all further sessions.
    //
    // An active instance on a live engine is NOT dirty: the host
    // asks about the *next* session (the "Quit and play" flow
    // queries while the current session runs or tears down), and
    // the evaluation below already predicts the post-retire answer -
    // a dylib island mints a fresh image, a static island was marked
    // used at acquire.
    if (s_activeBinding && mkxp_isEngineTerminated())
        return MKXP_SESSION_CAP_DIRTY;

    // Same resolution order as acquire, so the answer reflects the
    // island a session would actually run on.
    IslandSlot *requested = slotFor(version);
    IslandSlot *chain[4] = {requested, &s_slots[2], &s_slots[1], &s_slots[0]};
    for (int i = 0; i < 4; ++i) {
        IslandSlot *slot = chain[i];
        if (i > 0 && slot == requested)
            continue;
        resolveDylib(*slot);
        if (slot->dylibPresent)
            return MKXP_SESSION_CAP_FRESH;
        if (slot->staticEntry())
            return slot->staticUsed ? MKXP_SESSION_CAP_DIRTY
                                    : MKXP_SESSION_CAP_FRESH;
    }
    return MKXP_SESSION_CAP_UNAVAILABLE;
}

} // extern "C"

#endif // MKXPZ_MOBILE
