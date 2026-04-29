// app_bridge.cpp - Minimal C bridge for host overlay to query engine state.
// Kept separate from engine code. No UIKit imports. No game logic.

#include "app_bridge.h"
#include "sharedstate.h"
#include "graphics.h"
#include "audio.h"
#include "eventthread.h"
#include "config.h"
#include <atomic>
#include <cstring>
#include <mutex>
#include <condition_variable>
#include <string>
#include <vector>

#include <SDL.h>

#if TARGET_OS_IPHONE
#include <CoreFoundation/CoreFoundation.h>
#endif

static std::atomic<bool> s_gameReady{false};

// Debug log path for Ruby errors (empty = disabled).
static std::mutex s_debugLogMutex;
static std::string s_debugLogPath;
static FILE *s_debugLogFile = nullptr;

// Game path selection: Library sets the path, engine waits for it.
static std::mutex s_pathMutex;
static std::string s_gamePath;
static std::atomic<bool> s_pathSet{false};

// Engine terminated flag: set by engine after full teardown.
static std::atomic<bool> s_engineTerminated{false};
static std::atomic<bool> s_terminateRequested{false};
// Set when the current session ended because the Ruby VM raised
// SystemExit (e.g. an "Exit to desktop" menu in the game called
// Kernel.exit). The engine's main loop distinguishes this from a
// crash so the Swift layer can return to the library silently
// instead of showing the "game didn't exit cleanly" alert.
static std::atomic<bool> s_engineExitedCleanly{false};
// Set when the RGSS thread failed to ack a termination request in time.
// The UI reads this via mkxp_isEngineHung() and force-quits the app
// because the single-reused-thread architecture cannot recover.
static std::atomic<bool> s_engineHung{false};
static std::atomic<bool> s_glContextBroken{false};

// Game viewport rect in logical points, updated by the engine each frame.
static std::atomic<float> s_gameRectX{0};
static std::atomic<float> s_gameRectY{0};
static std::atomic<float> s_gameRectW{0};
static std::atomic<float> s_gameRectH{0};

// Cached safe area insets in logical points, pushed from UIKit.
static std::atomic<float> s_safeAreaTop{0};
static std::atomic<float> s_safeAreaBottom{0};
static std::atomic<float> s_safeAreaLeft{0};
static std::atomic<float> s_safeAreaRight{0};
static std::atomic<bool>  s_safeAreaInsetsChanged{false};

// Per-game settings: vertical alignment and postload toggle.
static std::atomic<int>   s_verticalAlignment{1};  // 0=top, 1=top-center, 2=center
static std::atomic<bool>  s_postloadEnabled{true};

// Per-game syntax-transform mode. The host (Empo on iOS) sets this
// before each session via mkxp_setSyntaxTransformMode to keep the
// choice out of mkxp.json - it's an Empo / per-game concept, not
// part of the developer's engine-config layer. See app_bridge.h
// for the enum and rationale.
static std::atomic<int>   s_syntaxTransformMode{MKXP_SYNTAX_TRANSFORM_UNSET};

// Per-game "force the in-game keyboard scene for PE text entry"
// toggle. Default false = the iOS soft keyboard handles name
// entry. Empo flips it on per-game when a Pokemon Essentials
// game's keyboard scene has custom keys not on the iOS keyboard.
// Read by `pokemon_input.rb`.
static std::atomic<bool>  s_useInGameKeyboard{false};

// Debug: tint the area outside the game viewport.
static std::atomic<bool>  s_showViewportBounds{false};
static std::atomic<float> s_vpBoundsR{0};
static std::atomic<float> s_vpBoundsG{0};
static std::atomic<float> s_vpBoundsB{0};
static std::atomic<float> s_vpBoundsA{1};

// Cheat menu toggle. Polled by a Ruby bridge helper that keeps the
// $CHEATS global in sync so the JoiPlay-ported cheat scripts pick
// up UI toggles immediately.
static std::atomic<bool>  s_cheatsEnabled{false};

// Input bridge: cached SDL window ID for event injection.
static std::atomic<uint32_t> s_sdlWindowID{0};

// Generic holder for a callback + userdata pair. Prior code split these
// across `std::atomic<Fn>` + bare `void *`: a setter wrote userdata
// (non-atomic) then the pointer (release), and a reader could still
// observe an old pointer with the new userdata, or the compiler could
// reorder around the non-atomic write on teardown. Packing both into a
// single shared_ptr makes set and fire see a consistent tuple.
template <typename Fn>
struct BridgeCallback {
    struct Slot {
        Fn fn;
        void *userdata;
    };

    // shared_ptr<const Slot> so the setter can CAS a new slot while an
    // in-flight caller still holds a reference to the old one.
    std::shared_ptr<const Slot> slot;
    std::mutex slotMutex;

    void set(Fn fn, void *userdata) noexcept {
        auto next = std::make_shared<const Slot>(Slot{fn, userdata});
        std::lock_guard<std::mutex> lock(slotMutex);
        slot = next;
    }

    // Snapshot the current slot and hand it to the caller. The caller
    // holds a strong ref so even a concurrent set() can't pull the
    // slot out from under them.
    std::shared_ptr<const Slot> snapshot() noexcept {
        std::lock_guard<std::mutex> lock(slotMutex);
        return slot;
    }

    // Convenience: load + fire in one go. Args are forwarded straight
    // to the stored function pointer; userdata is appended.
    template <typename... Args>
    void fire(Args&&... args) noexcept {
        if (auto s = snapshot(); s && s->fn) {
            s->fn(std::forward<Args>(args)..., s->userdata);
        }
    }

    void clear() noexcept {
        std::lock_guard<std::mutex> lock(slotMutex);
        slot.reset();
    }
};

// Key event callback: engine -> UI notification for hardware key events.
static BridgeCallback<mkxp_KeyEventCallback> s_keyEventCb;
static bool s_keyWatcherInstalled = false;

// Text-input mode change callback: engine -> UI notification when
// SDL_StartTextInput / SDL_StopTextInput fires inside EventThread.
static BridgeCallback<mkxp_TextInputModeCallback> s_textInputModeCb;

// Managed-config directory the host UI (Empo on iOS) sets before
// launching a session. Engine modules look here first for files
// they used to read from cwd (mkxp.json, patches.json, ...). Empty
// string means "no override; use cwd as before".
static std::mutex s_managedConfigMutex;
static std::string s_managedConfigDir;

// Game-side text-input intent. Set when the engine processes
// REQUEST_TEXTMODE(1) (game called `Input.text_input = true`),
// cleared on REQUEST_TEXTMODE(0). Distinct from
// `SDL_IsTextInputActive()` because SDL's iOS backend auto-stops
// text input on keyboard-hide notifications - which fire briefly
// even when our own UITextField becomes first responder, leaving
// SDL's state OFF while the game's Ruby loop still expects input.
// `mkxp_isTextInputActive()` reads this flag instead of asking SDL.
static std::atomic<bool> s_gameTextInputIntent{false};

// Lifecycle callbacks: engine -> UI notifications for state changes.
static BridgeCallback<mkxp_EngineTerminatedCallback> s_engineTerminatedCb;
static BridgeCallback<mkxp_GameRectChangedCallback> s_gameRectChangedCb;

// Error message routing: engine -> UI.
static std::mutex s_errorMsgMutex;
static std::string s_errorMessage;
static BridgeCallback<mkxp_ErrorMessageCallback> s_errorMsgCb;

// Pause / Resume state.
static std::atomic<bool> s_pauseRequested{false};
static std::atomic<bool> s_paused{false};
static std::mutex s_pauseMutex;
static std::condition_variable s_pauseCV;

// Snapshot buffer: owned by the bridge, written by engine, read by UI.
static std::mutex s_snapshotMutex;
static std::vector<unsigned char> s_snapshotData;
static int s_snapshotWidth = 0;
static int s_snapshotHeight = 0;

// Pause/resume callbacks.
static BridgeCallback<mkxp_PausedCallback> s_pausedCb;
static BridgeCallback<mkxp_ResumedCallback> s_resumedCb;

// Frame-rendered-after-resume: one-shot signal so the UI knows
// the live SDL surface is visible and the snapshot can fade out.
static std::atomic<bool> s_needsFrameRenderedSignal{false};
static BridgeCallback<mkxp_FrameRenderedCallback> s_frameRenderedCb;

extern "C" {

void mkxp_setGameReady(void) {
    s_gameReady.store(true, std::memory_order_release);
    // Arm the frame-rendered signal so the UI knows when the first
    // frame has actually been swapped to the screen.
    s_needsFrameRenderedSignal.store(true, std::memory_order_release);
}

int mkxp_isGameReady(void) {
    return s_gameReady.load(std::memory_order_acquire) ? 1 : 0;
}

void mkxp_setGamePath(const char *path) {
    std::lock_guard<std::mutex> lock(s_pathMutex);
    s_gamePath = path ? path : "";
    s_pathSet.store(true, std::memory_order_release);
    // A fresh session: clear any clean-exit flag set by the
    // previous session so the termination callback for this one
    // starts from the default "unclean unless proven clean" state.
    s_engineExitedCleanly.store(false, std::memory_order_release);
}

const char *mkxp_waitForGamePath(void) {
#if TARGET_OS_IPHONE
    // On iOS, SDL_main runs on the main thread. We must pump the main
    // run loop while waiting so that UIKit can render the Library UI
    // and dispatch_async blocks can execute.
    while (!s_pathSet.load(std::memory_order_acquire)) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
#else
    while (!s_pathSet.load(std::memory_order_acquire)) {
        // spin (non-iOS fallback, shouldn't be reached)
    }
#endif
    // Copy under lock so the returned c_str() remains valid until the
    // next call from this thread (thread_local lifetime).
    thread_local std::string pathCopy;
    std::lock_guard<std::mutex> lock(s_pathMutex);
    pathCopy = s_gamePath;
    return pathCopy.c_str();
}

void mkxp_requestTerminate(void) {
    s_terminateRequested.store(true, std::memory_order_release);

    // If the engine is paused on the condvar, unblock it so it can
    // process SDL_QUIT. This avoids needing a separate resume call.
    {
        std::lock_guard<std::mutex> lock(s_pauseMutex);
        s_paused.store(false, std::memory_order_release);
        s_pauseRequested.store(false, std::memory_order_release);
    }
    s_pauseCV.notify_one();

    // Push SDL_QUIT into the event queue. The engine's event loop
    // will pick it up and initiate normal shutdown.
    SDL_Event event;
    event.type = SDL_QUIT;
    SDL_PushEvent(&event);
}

int mkxp_isEngineTerminated(void) {
    return s_engineTerminated.load(std::memory_order_acquire) ? 1 : 0;
}

int mkxp_didEngineExitCleanly(void) {
    return s_engineExitedCleanly.load(std::memory_order_acquire) ? 1 : 0;
}

void mkxp_setEngineExitedCleanly(void) {
    s_engineExitedCleanly.store(true, std::memory_order_release);
}

int mkxp_isEngineHung(void) {
    return s_engineHung.load(std::memory_order_acquire) ? 1 : 0;
}

void mkxp_setEngineHung(void) {
    s_engineHung.store(true, std::memory_order_release);
}

void mkxp_setEngineTerminated(void) {
    s_engineTerminated.store(true, std::memory_order_release);
    // Clear pathSet so the next mkxp_waitForGamePath() actually blocks
    // until the Library UI provides a new game selection.
    s_pathSet.store(false, std::memory_order_release);
    s_engineTerminatedCb.fire();
}

void mkxp_resetBridgeState(void) {
    s_gameReady.store(false, std::memory_order_release);
    s_pathSet.store(false, std::memory_order_release);
    s_engineTerminated.store(false, std::memory_order_release);
    s_terminateRequested.store(false, std::memory_order_release);
    s_gameRectX.store(0, std::memory_order_relaxed);
    s_gameRectY.store(0, std::memory_order_relaxed);
    s_gameRectW.store(0, std::memory_order_relaxed);
    s_gameRectH.store(0, std::memory_order_relaxed);
    // Note: s_verticalAlignment and s_postloadEnabled are NOT reset here.
    // They are explicitly set by selectGame() before each session.
    s_sdlWindowID.store(0, std::memory_order_relaxed);
    // Game-driven text-input intent (set by Ruby `Input.text_input=`).
    // Not part of the per-game settings group above because Empo
    // doesn't seed it - the game itself flips it on entry to a name
    // entry / chat input UI. Force-reset between sessions in case
    // the previous session was force-quit (OS kill, crash) while the
    // intent was still true; without this clear, the next session
    // would inherit the flag and the soft keyboard would auto-show
    // before the game asked for it.
    s_gameTextInputIntent.store(false, std::memory_order_relaxed);
    // Reset pause state so a stale pause doesn't block the next session.
    s_pauseRequested.store(false, std::memory_order_relaxed);
    s_paused.store(false, std::memory_order_relaxed);
    s_needsFrameRenderedSignal.store(false, std::memory_order_relaxed);
    s_glContextBroken.store(false, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> lock(s_snapshotMutex);
        s_snapshotData.clear();
        s_snapshotWidth = 0;
        s_snapshotHeight = 0;
    }
    {
        std::lock_guard<std::mutex> lock(s_pathMutex);
        s_gamePath.clear();
    }
}

double mkxp_getAverageFPS(void) {
    if (s_engineTerminated.load(std::memory_order_acquire)) return 0.0;
    if (!SharedState::instance) return 0.0;
    return SharedState::instance->graphics().averageFrameRate();
}

int mkxp_getRGSSVersion(void) {
    if (s_engineTerminated.load(std::memory_order_acquire)) return 0;
    if (!SharedState::instance) return 0;
    return SharedState::instance->rtData().config.rgssVersion;
}

int mkxp_getSupportedRGSSVersionMask(void) {
    // Ruby 1.8 reliably runs RGSS1 and RGSS2 (both use 1.8-era syntax).
    // RGSS3 requires Ruby 1.9+ which in this build means Ruby 3.1 with
    // the syntax-transform patches. MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES
    // is defined by the build system only when the patched Ruby is
    // linked; it stays undefined on unpatched builds.
#if defined(MKXPZ_HAVE_SYNTAX_TRANSFORM_PATCHES)
    return (1 << 0) | (1 << 1) | (1 << 2);
#else
    return (1 << 0) | (1 << 1);
#endif
}

const char *mkxp_getRubyVersion(void) {
    // The build system injects MKXPZ_RUBY_VERSION as a quoted string
    // literal (e.g. "3.1" / "1.8") matching the linked Ruby runtime.
    // If the define is missing the bridge returns "unknown" and logs
    // once so the discrepancy is noticed in debug logs rather than
    // silently misreporting a version.
#if defined(MKXPZ_RUBY_VERSION)
    return MKXPZ_RUBY_VERSION;
#else
    static std::atomic<bool> warned{false};
    bool expected = false;
    if (warned.compare_exchange_strong(expected, true)) {
        mkxp_debugLog("BRIDGE", "app_bridge.cpp [C++]",
                      "MKXPZ_RUBY_VERSION is not defined; build system "
                      "should inject it via GCC_PREPROCESSOR_DEFINITIONS. "
                      "Reporting \"unknown\" to the UI.");
    }
    return "unknown";
#endif
}

const char *mkxp_getGameTitle(void) {
    if (s_engineTerminated.load(std::memory_order_acquire)) return "";
    if (!SharedState::instance) return "";
    return SharedState::instance->rtData().config.game.title.c_str();
}

void mkxp_setGameRect(float x, float y, float w, float h) {
    float oldX = s_gameRectX.exchange(x, std::memory_order_relaxed);
    float oldY = s_gameRectY.exchange(y, std::memory_order_relaxed);
    float oldW = s_gameRectW.exchange(w, std::memory_order_relaxed);
    float oldH = s_gameRectH.exchange(h, std::memory_order_relaxed);
    if (x != oldX || y != oldY || w != oldW || h != oldH) {
        s_gameRectChangedCb.fire(x, y, w, h);
    }
}

void mkxp_getSafeAreaInsets(float *top, float *bottom, float *left, float *right) {
    if (top)    *top    = s_safeAreaTop.load(std::memory_order_relaxed);
    if (bottom) *bottom = s_safeAreaBottom.load(std::memory_order_relaxed);
    if (left)   *left   = s_safeAreaLeft.load(std::memory_order_relaxed);
    if (right)  *right  = s_safeAreaRight.load(std::memory_order_relaxed);
}

void mkxp_setSafeAreaInsets(float top, float bottom, float left, float right) {
    float oldTop    = s_safeAreaTop.load(std::memory_order_relaxed);
    float oldBottom = s_safeAreaBottom.load(std::memory_order_relaxed);
    float oldLeft   = s_safeAreaLeft.load(std::memory_order_relaxed);
    float oldRight  = s_safeAreaRight.load(std::memory_order_relaxed);
    s_safeAreaTop.store(top, std::memory_order_relaxed);
    s_safeAreaBottom.store(bottom, std::memory_order_relaxed);
    s_safeAreaLeft.store(left, std::memory_order_relaxed);
    s_safeAreaRight.store(right, std::memory_order_relaxed);
    if (top != oldTop || bottom != oldBottom || left != oldLeft || right != oldRight) {
        s_safeAreaInsetsChanged.store(true, std::memory_order_release);
    }
}

bool mkxp_consumeSafeAreaInsetsChanged(void) {
    return s_safeAreaInsetsChanged.exchange(false, std::memory_order_acquire);
}

// Input bridge

void mkxp_injectKeyEvent(int scancode, int pressed) {
    if (s_sdlWindowID.load(std::memory_order_relaxed) == 0) {
        SDL_Window *w = SDL_GetGrabbedWindow();
        if (w) {
            s_sdlWindowID.store(SDL_GetWindowID(w), std::memory_order_relaxed);
        } else {
            // Single-window app: SDL window IDs start at 1
            s_sdlWindowID.store(1, std::memory_order_relaxed);
        }
    }

    SDL_Event event{};
    event.type              = pressed ? SDL_KEYDOWN : SDL_KEYUP;
    event.key.timestamp     = SDL_GetTicks();
    event.key.windowID      = s_sdlWindowID.load(std::memory_order_relaxed);
    event.key.state         = pressed ? SDL_PRESSED : SDL_RELEASED;
    event.key.repeat        = 0;
    event.key.keysym.scancode = (SDL_Scancode)scancode;
    event.key.keysym.sym    = SDL_GetKeyFromScancode((SDL_Scancode)scancode);
    event.key.keysym.mod    = KMOD_NONE;
    SDL_PushEvent(&event);
}

static int keyEventWatcherFn(void * /*userdata*/, SDL_Event *event) {
    if (event->type == SDL_KEYDOWN || event->type == SDL_KEYUP) {
        int pressed = (event->type == SDL_KEYDOWN) ? 1 : 0;
        int sc = (int)event->key.keysym.scancode;
        s_keyEventCb.fire(sc, pressed);
    }
    return 1; // keep processing the event
}

void mkxp_setKeyEventCallback(mkxp_KeyEventCallback cb, void *userdata) {
    s_keyEventCb.set(cb, userdata);
    if (!s_keyWatcherInstalled) {
        SDL_AddEventWatch(keyEventWatcherFn, NULL);
        s_keyWatcherInstalled = true;
    }
}

// Text-input bridge

void mkxp_setTextInputModeCallback(mkxp_TextInputModeCallback cb, void *userdata) {
    s_textInputModeCb.set(cb, userdata);
}

// Internal hook called by EventThread::process whenever
// SDL_StartTextInput / SDL_StopTextInput is dispatched. Lives in
// app_bridge so the BridgeCallback machinery (mutex + atomic gate)
// stays internal to this translation unit. Also flips the
// `s_gameTextInputIntent` flag the UI side queries via
// `mkxp_isTextInputActive`.
void mkxp_fireTextInputModeCallback(int active) {
    s_gameTextInputIntent.store(active != 0, std::memory_order_release);
    s_textInputModeCb.fire(active);
}

// Managed-config directory accessors.

void mkxp_setManagedConfigDir(const char *path) {
    std::lock_guard<std::mutex> lock(s_managedConfigMutex);
    s_managedConfigDir = (path && *path) ? std::string(path) : std::string();
}

const char *mkxp_getManagedConfigDir(void) {
    std::lock_guard<std::mutex> lock(s_managedConfigMutex);
    /* Pointer remains valid as long as `s_managedConfigDir` isn't
     * reassigned. Engine call sites are expected to copy the
     * result into a std::string immediately if they need to keep
     * it; we don't return a snapshot to avoid forcing every
     * caller through an allocation. */
    return s_managedConfigDir.c_str();
}

int mkxp_isTextInputActive(void) {
    /* Game-side intent (the `Input.text_input = true` flag) rather
     * than `SDL_IsTextInputActive()`. SDL's iOS backend
     * (SDL_uikitviewcontroller.m `keyboardWillHide`) auto-calls
     * SDL_StopTextInput when the keyboard transiently hides during
     * appearance - even when OUR own UITextField is the one being
     * presented. That leaves SDL's flag FALSE while the Ruby
     * `Input.gets` loop is still polling for typed characters; if
     * we gated text-event pushing on SDL's flag we'd drop every
     * keystroke after the first hide flicker. */
    return s_gameTextInputIntent.load(std::memory_order_acquire) ? 1 : 0;
}

void mkxp_pushTextInput(const char *utf8) {
    if (!utf8 || !*utf8) return;

    // SDL_TEXTINPUT.text is `char[32]` including the trailing NUL,
    // so the largest payload per event is 31 bytes. We split the
    // input on UTF-8 character boundaries (never mid-codepoint) and
    // emit one event per chunk.
    //
    // UTF-8 leading-byte detection: a byte is a continuation byte
    // iff `(b & 0xC0) == 0x80`. We walk forward up to 31 bytes,
    // then back off to the most recent leading byte so the chunk
    // ends on a complete codepoint.
    constexpr size_t kMaxChunk = 31;

    if (s_sdlWindowID.load(std::memory_order_relaxed) == 0) {
        SDL_Window *w = SDL_GetGrabbedWindow();
        if (w) {
            s_sdlWindowID.store(SDL_GetWindowID(w), std::memory_order_relaxed);
        } else {
            s_sdlWindowID.store(1, std::memory_order_relaxed);
        }
    }
    Uint32 winID = s_sdlWindowID.load(std::memory_order_relaxed);

    const char *p = utf8;
    size_t remaining = std::strlen(utf8);
    while (remaining > 0) {
        size_t chunk = remaining > kMaxChunk ? kMaxChunk : remaining;

        // If we're truncating mid-string, walk back to the last
        // leading byte so we don't split a multi-byte codepoint.
        if (chunk < remaining) {
            while (chunk > 0 && (((unsigned char)p[chunk]) & 0xC0) == 0x80)
                --chunk;
            if (chunk == 0) {
                // Pathological input (continuation bytes only); bail
                // out rather than infinite-loop.
                return;
            }
        }

        SDL_Event event{};
        event.type            = SDL_TEXTINPUT;
        event.text.timestamp  = SDL_GetTicks();
        event.text.windowID   = winID;
        std::memcpy(event.text.text, p, chunk);
        event.text.text[chunk] = '\0';
        SDL_PushEvent(&event);

        p         += chunk;
        remaining -= chunk;
    }
}

// Lifecycle callbacks

void mkxp_setEngineTerminatedCallback(mkxp_EngineTerminatedCallback cb, void *userdata) {
    s_engineTerminatedCb.set(cb, userdata);
}

void mkxp_setGameRectChangedCallback(mkxp_GameRectChangedCallback cb, void *userdata) {
    s_gameRectChangedCb.set(cb, userdata);
}

// Error message routing

void mkxp_setErrorMessage(const char *message) {
    {
        std::lock_guard<std::mutex> lock(s_errorMsgMutex);
        s_errorMessage = message ? message : "";
    }
    if (message && message[0]) {
        s_errorMsgCb.fire(message);
    }
}

void mkxp_setErrorMessageCallback(mkxp_ErrorMessageCallback cb, void *userdata) {
    s_errorMsgCb.set(cb, userdata);
}

// Pause / Resume

void mkxp_requestPause(void) {
    s_pauseRequested.store(true, std::memory_order_release);
}

void mkxp_requestResume(void) {
    {
        std::lock_guard<std::mutex> lock(s_pauseMutex);
        s_pauseRequested.store(false, std::memory_order_release);
        s_paused.store(false, std::memory_order_release);
    }
    // Arm the one-shot frame-rendered signal so the UI knows when the
    // first post-resume frame has been swapped to the screen.
    s_needsFrameRenderedSignal.store(true, std::memory_order_release);
    s_pauseCV.notify_one();
}

void mkxp_checkPause(void) {
    if (!s_pauseRequested.load(std::memory_order_acquire) &&
        !s_paused.load(std::memory_order_acquire))
        return;

    /* Pause every AL_PLAYING source.  We intentionally do NOT
     * detach the OpenAL context — keeping it current avoids
     * any audio blip that Apple's implementation produces when
     * a context is restored via alcMakeContextCurrent(). */
    if (SharedState::instance)
        SharedState::instance->audio().pauseSources();

    s_paused.store(true, std::memory_order_release);

    s_pausedCb.fire();

    /* Block until resume is requested. */
    std::unique_lock<std::mutex> lock(s_pauseMutex);
    s_pauseCV.wait(lock, [] {
        return !s_paused.load(std::memory_order_acquire);
    });

    if (!s_terminateRequested.load(std::memory_order_acquire)) {
        /* Normal resume — un-pause the sources we paused. */
        if (SharedState::instance)
            SharedState::instance->audio().resumeSources();
    }
    /* On terminate the sources stay paused (silent) until
     * SharedState::finiInstance() deletes them. */

    s_resumedCb.fire();
}

bool mkxp_isPauseRequested(void) {
    return s_pauseRequested.load(std::memory_order_acquire);
}

bool mkxp_isPaused(void) {
    return s_paused.load(std::memory_order_acquire);
}

void mkxp_setSnapshot(const unsigned char *data, int width, int height) {
    std::lock_guard<std::mutex> lock(s_snapshotMutex);
    size_t size = (size_t)width * height * 4;
    s_snapshotData.assign(data, data + size);
    s_snapshotWidth = width;
    s_snapshotHeight = height;
}

const unsigned char *mkxp_getSnapshotRGBA(int *width, int *height) {
    std::lock_guard<std::mutex> lock(s_snapshotMutex);
    if (s_snapshotData.empty()) return nullptr;
    if (width) *width = s_snapshotWidth;
    if (height) *height = s_snapshotHeight;
    return s_snapshotData.data();
}

bool mkxp_copySnapshotRGBA(unsigned char *dest, int destSize, int *width, int *height) {
    std::lock_guard<std::mutex> lock(s_snapshotMutex);
    if (s_snapshotData.empty()) return false;
    int size = (int)s_snapshotData.size();
    if (destSize < size) return false;
    memcpy(dest, s_snapshotData.data(), size);
    if (width) *width = s_snapshotWidth;
    if (height) *height = s_snapshotHeight;
    return true;
}

bool mkxp_getSnapshotSize(int *width, int *height) {
    std::lock_guard<std::mutex> lock(s_snapshotMutex);
    if (s_snapshotData.empty()) return false;
    if (width) *width = s_snapshotWidth;
    if (height) *height = s_snapshotHeight;
    return true;
}

void mkxp_setPausedCallback(mkxp_PausedCallback cb, void *userdata) {
    s_pausedCb.set(cb, userdata);
}

void mkxp_setResumedCallback(mkxp_ResumedCallback cb, void *userdata) {
    s_resumedCb.set(cb, userdata);
}

void mkxp_setFrameRenderedCallback(mkxp_FrameRenderedCallback cb, void *userdata) {
    s_frameRenderedCb.set(cb, userdata);
}

void mkxp_signalFrameRendered(void) {
    if (s_needsFrameRenderedSignal.exchange(false, std::memory_order_acq_rel)) {
        s_frameRenderedCb.fire();
    }
}

// Per-game settings

void mkxp_applyPerGameSettings(MKXPVerticalAlignment verticalAlignment,
                               bool postloadEnabled) {
    int oldAlign = s_verticalAlignment.exchange((int)verticalAlignment, std::memory_order_relaxed);
    if (oldAlign != (int)verticalAlignment) {
        s_safeAreaInsetsChanged.store(true, std::memory_order_release);
    }
    s_postloadEnabled.store(postloadEnabled, std::memory_order_relaxed);
}

MKXPVerticalAlignment mkxp_getVerticalAlignment(void) {
    return (MKXPVerticalAlignment)s_verticalAlignment.load(std::memory_order_relaxed);
}

bool mkxp_getPostloadEnabled(void) {
    return s_postloadEnabled.load(std::memory_order_relaxed);
}

void mkxp_setSyntaxTransformMode(MKXPSyntaxTransformMode mode) {
    s_syntaxTransformMode.store((int)mode, std::memory_order_release);
}

MKXPSyntaxTransformMode mkxp_getSyntaxTransformMode(void) {
    return (MKXPSyntaxTransformMode)s_syntaxTransformMode.load(std::memory_order_acquire);
}

void mkxp_setUseInGameKeyboard(bool enabled) {
    s_useInGameKeyboard.store(enabled, std::memory_order_release);
}

bool mkxp_getUseInGameKeyboard(void) {
    return s_useInGameKeyboard.load(std::memory_order_acquire);
}

void mkxp_setShowViewportBounds(bool enabled) {
    s_showViewportBounds.store(enabled, std::memory_order_relaxed);
}

bool mkxp_getShowViewportBounds(void) {
    return s_showViewportBounds.load(std::memory_order_relaxed);
}

void mkxp_setCheatsEnabled(bool enabled) {
    s_cheatsEnabled.store(enabled, std::memory_order_relaxed);
}

bool mkxp_getCheatsEnabled(void) {
    return s_cheatsEnabled.load(std::memory_order_relaxed);
}

void mkxp_setViewportBoundsColor(float r, float g, float b, float a) {
    s_vpBoundsR.store(r, std::memory_order_relaxed);
    s_vpBoundsG.store(g, std::memory_order_relaxed);
    s_vpBoundsB.store(b, std::memory_order_relaxed);
    s_vpBoundsA.store(a, std::memory_order_relaxed);
}

void mkxp_getViewportBoundsColor(float *r, float *g, float *b, float *a) {
    if (r) *r = s_vpBoundsR.load(std::memory_order_relaxed);
    if (g) *g = s_vpBoundsG.load(std::memory_order_relaxed);
    if (b) *b = s_vpBoundsB.load(std::memory_order_relaxed);
    if (a) *a = s_vpBoundsA.load(std::memory_order_relaxed);
}

void mkxp_setGLContextBroken(void) {
    s_glContextBroken.store(true, std::memory_order_release);
}

bool mkxp_isGLContextBroken(void) {
    return s_glContextBroken.load(std::memory_order_acquire);
}

// Runtime fast-forward toggle. Read by Graphics::FPSLimiter::delay()
// each frame: when true, the limiter scales its target ticks-per-frame
// down so the engine paces 4x as fast as the configured framerate.
// Default 1x, capped at 4x for stability (audio/input timers don't
// always cope with arbitrary multipliers).
static std::atomic<bool> s_fastForwardActive{false};

void mkxp_setFastForwardActive(int active) {
    s_fastForwardActive.store(active != 0, std::memory_order_release);
}

int mkxp_isFastForwardActive(void) {
    return s_fastForwardActive.load(std::memory_order_acquire) ? 1 : 0;
}

void mkxp_setDebugLogPath(const char *path) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    // Close previous file handle if open
    if (s_debugLogFile) {
        fclose(s_debugLogFile);
        s_debugLogFile = nullptr;
    }
    s_debugLogPath = (path && path[0]) ? path : "";
    // Open new file handle for the session
    if (!s_debugLogPath.empty()) {
        s_debugLogFile = fopen(s_debugLogPath.c_str(), "a");
    }
}

// Fast-path check so callers in hot paths (resize handler, frame boundary)
// can skip expensive formatting when logging is disabled.
int mkxp_debugLogEnabled(void) {
    // Reading s_debugLogFile without the mutex is safe enough here: the
    // worst outcome is a dropped or duplicated log line if the file is
    // being opened/closed on another thread at the same moment. For a
    // debug log that's acceptable and avoids serializing the entire
    // engine on every hot-path check.
    return s_debugLogFile ? 1 : 0;
}

void mkxp_debugLog(const char *tag, const char *source, const char *message) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    if (!s_debugLogFile) return;
    fprintf(s_debugLogFile, "[%s] (%s) %s\n", tag, source, message);
    // Flush immediately: the RGSS thread's log writes otherwise sit in
    // stdio's per-FILE buffer until the file closes on the next
    // session's setDebugLogPath. If the engine stalls or the user
    // dismisses an error alert and stays in the same session, those
    // buffered lines are invisible - which made diagnosing the
    // "Unable to load scripts" issue on-device impossible because
    // the diagnostic lines never reached disk.
    fflush(s_debugLogFile);
}

} // extern "C"

// Internal helper — called by binding-mri.cpp, not part of the C bridge.
// Returns empty string if logging is disabled.
std::string mkxp_getDebugLogPath(void) {
    std::lock_guard<std::mutex> lock(s_debugLogMutex);
    return s_debugLogPath;
}
