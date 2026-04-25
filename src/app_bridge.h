// app_bridge.h - C-linkage bridge between mkxp-z engine and host UI layer.
//
// This header is the ONLY interface between the engine and the UI.
// The UI side must not import any engine headers (SDL, SharedState, etc.).
// The engine side must not import any UI headers (UIKit, SwiftUI, etc.).
// Both sides communicate exclusively through these functions.

#ifndef IOS_BRIDGE_H
#define IOS_BRIDGE_H

#include <stdbool.h>
// Scancode constants
//
// Values match SDL_Scancode (USB HID usage page 0x07) so the engine
// can pass them through without translation. UI code should use these
// instead of importing SDL headers.

enum {
    MKXP_SCANCODE_UNKNOWN   = 0,

    // Letters
    MKXP_SCANCODE_A = 4,  MKXP_SCANCODE_B = 5,  MKXP_SCANCODE_C = 6,
    MKXP_SCANCODE_D = 7,  MKXP_SCANCODE_E = 8,  MKXP_SCANCODE_F = 9,
    MKXP_SCANCODE_G = 10, MKXP_SCANCODE_H = 11, MKXP_SCANCODE_I = 12,
    MKXP_SCANCODE_J = 13, MKXP_SCANCODE_K = 14, MKXP_SCANCODE_L = 15,
    MKXP_SCANCODE_M = 16, MKXP_SCANCODE_N = 17, MKXP_SCANCODE_O = 18,
    MKXP_SCANCODE_P = 19, MKXP_SCANCODE_Q = 20, MKXP_SCANCODE_R = 21,
    MKXP_SCANCODE_S = 22, MKXP_SCANCODE_T = 23, MKXP_SCANCODE_U = 24,
    MKXP_SCANCODE_V = 25, MKXP_SCANCODE_W = 26, MKXP_SCANCODE_X = 27,
    MKXP_SCANCODE_Y = 28, MKXP_SCANCODE_Z = 29,

    // Digits
    MKXP_SCANCODE_1 = 30, MKXP_SCANCODE_2 = 31, MKXP_SCANCODE_3 = 32,
    MKXP_SCANCODE_4 = 33, MKXP_SCANCODE_5 = 34, MKXP_SCANCODE_6 = 35,
    MKXP_SCANCODE_7 = 36, MKXP_SCANCODE_8 = 37, MKXP_SCANCODE_9 = 38,
    MKXP_SCANCODE_0 = 39,

    // Control / whitespace
    MKXP_SCANCODE_RETURN    = 40,
    MKXP_SCANCODE_ESCAPE    = 41,
    MKXP_SCANCODE_BACKSPACE = 42,
    MKXP_SCANCODE_TAB       = 43,
    MKXP_SCANCODE_SPACE     = 44,

    // Punctuation / symbols
    MKXP_SCANCODE_MINUS        = 45,
    MKXP_SCANCODE_EQUALS       = 46,
    MKXP_SCANCODE_LEFTBRACKET  = 47,
    MKXP_SCANCODE_RIGHTBRACKET = 48,
    MKXP_SCANCODE_BACKSLASH    = 49,
    MKXP_SCANCODE_SEMICOLON    = 51,
    MKXP_SCANCODE_APOSTROPHE   = 52,
    MKXP_SCANCODE_GRAVE        = 53,
    MKXP_SCANCODE_COMMA        = 54,
    MKXP_SCANCODE_PERIOD       = 55,
    MKXP_SCANCODE_SLASH        = 56,

    // Function keys
    MKXP_SCANCODE_F1  = 58, MKXP_SCANCODE_F2  = 59, MKXP_SCANCODE_F3  = 60,
    MKXP_SCANCODE_F4  = 61, MKXP_SCANCODE_F5  = 62, MKXP_SCANCODE_F6  = 63,
    MKXP_SCANCODE_F7  = 64, MKXP_SCANCODE_F8  = 65, MKXP_SCANCODE_F9  = 66,
    MKXP_SCANCODE_F10 = 67, MKXP_SCANCODE_F11 = 68, MKXP_SCANCODE_F12 = 69,

    // Arrow keys
    MKXP_SCANCODE_RIGHT = 79,
    MKXP_SCANCODE_LEFT  = 80,
    MKXP_SCANCODE_DOWN  = 81,
    MKXP_SCANCODE_UP    = 82,

    // Modifiers
    MKXP_SCANCODE_LCTRL  = 224,
    MKXP_SCANCODE_LSHIFT = 225,
    MKXP_SCANCODE_LALT   = 226,

    // Navigation
    MKXP_SCANCODE_HOME   = 74,
};

#ifdef __cplusplus
extern "C" {
#endif

// Game lifecycle

void        mkxp_setGameReady(void);
int         mkxp_isGameReady(void);

// Game selection (Library -> Engine)

void        mkxp_setGamePath(const char *path);
const char *mkxp_waitForGamePath(void);

// Engine termination

void        mkxp_requestTerminate(void);
int         mkxp_isEngineTerminated(void);
void        mkxp_setEngineTerminated(void);
void        mkxp_resetBridgeState(void);

// Set by the engine when the current session ended because Ruby
// raised SystemExit (e.g. the game's "Exit to desktop" menu). The
// UI reads this in its engine-terminated callback to skip the
// "game didn't exit cleanly" alert for intentional exits.
int         mkxp_didEngineExitCleanly(void);
void        mkxp_setEngineExitedCleanly(void);

// Set when the RGSS thread failed to respond to a termination request.
// The engine is unrecoverable: the UI should force-quit the process
// because the single-reused-thread architecture cannot respawn it.
int         mkxp_isEngineHung(void);
void        mkxp_setEngineHung(void);

// Lifecycle callbacks (Engine -> UI)
//
// Fire on the engine thread. UI must dispatch to main for any updates.

typedef void (*mkxp_EngineTerminatedCallback)(void *userdata);
void        mkxp_setEngineTerminatedCallback(mkxp_EngineTerminatedCallback cb, void *userdata);

typedef void (*mkxp_GameRectChangedCallback)(float x, float y, float w, float h, void *userdata);
void        mkxp_setGameRectChangedCallback(mkxp_GameRectChangedCallback cb, void *userdata);

// Input injection (UI -> Engine)

// scancode: MKXP_SCANCODE_* value. pressed: 1=down, 0=up.
void        mkxp_injectKeyEvent(int scancode, int pressed);

// Key event callback (Engine -> UI, fires on background thread)

typedef void (*mkxp_KeyEventCallback)(int scancode, int pressed, void *userdata);
void        mkxp_setKeyEventCallback(mkxp_KeyEventCallback cb, void *userdata);

// Managed-config directory (UI -> Engine)
//
// Empo keeps all per-game state it generates (mkxp.json,
// patches.json, save-state metadata, etc.) outside the game
// folder so the game directory stays a faithful mirror of what
// the user imported. The host UI calls
// `mkxp_setManagedConfigDir` with an absolute path to the
// per-game state directory before launching a session; engine
// modules that previously loaded config from cwd (Config::read,
// Patcher auto-discovery, ...) check this directory FIRST and
// fall back to cwd only if the file isn't found there.
//
// Pass NULL or "" to clear the override (fall back to cwd-only
// behaviour, matching desktop builds).
//
// Engine-side accessor: `mkxp_getManagedConfigDir()` returns
// the current path (empty string if unset).
void        mkxp_setManagedConfigDir(const char *path);
const char *mkxp_getManagedConfigDir(void);

// Text-input bridge (UI <-> Engine)
//
// Games request text input via Ruby `Input.text_input = true`, which
// triggers `SDL_StartTextInput()` inside EventThread. The callback
// registered with `mkxp_setTextInputModeCallback` fires from the main
// thread when that state changes; the iOS side uses it to auto-show
// the system keyboard so the user can immediately type without having
// to manually toggle the keyboard toolbar.
//
// `mkxp_pushTextInput(utf8)` is the inverse direction: the iOS soft
// keyboard's UITextField delegate forwards typed UTF-8 strings here,
// which are wrapped as SDL_TEXTINPUT events and end up in the engine's
// `textInputBuffer`. Ruby reads them via `Input.gets`. Strings longer
// than SDL's per-event limit (32 bytes including the trailing NUL) are
// chunked at safe UTF-8 boundaries.
//
// `mkxp_isTextInputActive()` lets the UI side check whether to push
// text events at all - when SDL text mode is OFF (e.g. user toggled
// the keyboard toolbar manually for a non-text scene), pushing text
// would silently fill the buffer with input nobody reads.
typedef void (*mkxp_TextInputModeCallback)(int active, void *userdata);
void        mkxp_setTextInputModeCallback(mkxp_TextInputModeCallback cb, void *userdata);
void        mkxp_pushTextInput(const char *utf8);
int         mkxp_isTextInputActive(void);

// Engine state queries

double      mkxp_getAverageFPS(void);
int         mkxp_getRGSSVersion(void);
const char *mkxp_getGameTitle(void);

// Bitmask of supported RGSS versions for this build.
// Bit 0 = RGSS1 (XP), bit 1 = RGSS2 (VX), bit 2 = RGSS3 (VX Ace).
// Determined at compile time by which Ruby runtime is linked.
int         mkxp_getSupportedRGSSVersionMask(void);

// Ruby runtime version the engine was built against.
// Example: "3.1" for Ruby 3.1, "1.8" for Ruby 1.8.
// The returned pointer is a static string literal, do not free.
const char *mkxp_getRubyVersion(void);

// ANGLE version string, extracted from GL_VERSION at engine init.
// Example: "2.1.0.abcdef1234". Returns "unknown" before the engine
// has initialized GL, or if the GL_VERSION string didn't match the
// expected ANGLE format. The returned pointer is a process-lifetime
// buffer, do not free.
const char *mkxp_getANGLEVersion(void);

// Metal device name, extracted from GL_RENDERER at engine init.
// Example: "Apple A15 GPU" or "Apple A17 Pro GPU". Returns "unknown"
// before the engine has initialized GL, or if the GL_RENDERER string
// didn't match the expected ANGLE format. The returned pointer is a
// process-lifetime buffer, do not free.
const char *mkxp_getMetalDeviceName(void);

// Game viewport rect (logical points)

void        mkxp_setGameRect(float x, float y, float w, float h);

// Safe area insets (logical points, cached atomics)

void        mkxp_getSafeAreaInsets(float *top, float *bottom, float *left, float *right);

// Push from UIKit main thread. Sets a "needs relayout" flag.
void        mkxp_setSafeAreaInsets(float top, float bottom, float left, float right);

// Returns true (once) if insets changed since last check.
bool        mkxp_consumeSafeAreaInsetsChanged(void);

// Screen scale factor (e.g. 3.0 on iPhone Pro).
float       mkxp_getScreenScale(void);

// Per-game settings (UI -> Engine, set before each session)
//
// Set by selectGame() before mkxp_setGamePath(), read by the engine
// during the session. NOT reset in mkxp_resetBridgeState() — selectGame()
// always sets them explicitly.
//
// To add a new setting:
//   1. Add a parameter to mkxp_applyPerGameSettings()
//   2. Add an atomic + getter in app_bridge.cpp
//   3. Add the field to GameSettings.swift, pass from AppState.selectGame()

typedef enum {
    MKXP_VALIGN_TOP        = 0,
    MKXP_VALIGN_TOP_CENTER = 1,
    MKXP_VALIGN_CENTER     = 2,
} MKXPVerticalAlignment;

void        mkxp_applyPerGameSettings(MKXPVerticalAlignment verticalAlignment,
                                      bool postloadEnabled);

MKXPVerticalAlignment mkxp_getVerticalAlignment(void);
bool        mkxp_getPostloadEnabled(void);

// Per-game `syntaxTransform` override.
//
// The Empo iOS host calls this on every selectGame() so mkxp.json
// stays free of host-managed keys (the developer's mkxp.json is
// snapshotted at import as mkxp.original.json and merged into the
// per-session mkxp.json without us writing syntaxTransform on top
// of the developer's intent).
//
// `MKXP_SYNTAX_TRANSFORM_UNSET` is the default at startup so
// desktop / test-harness builds that never call the setter keep
// the legacy mkxp.json-driven path. Numeric values match
// Config::syntaxTransform (0/1/2) since that's the engine's
// existing on-disk schema; the typed enum only exists at this
// boundary so callers don't sprinkle magic numbers around.
typedef enum {
    MKXP_SYNTAX_TRANSFORM_UNSET     = -1,
    MKXP_SYNTAX_TRANSFORM_DISABLED  = 0,  // Ruby 3 strict
    MKXP_SYNTAX_TRANSFORM_CUSTOM    = 1,  // syntaxTransformCustomVersion* from mkxp.json
    MKXP_SYNTAX_TRANSFORM_LEGACY    = 2,  // Ruby 1.9 for RGSS3, Ruby 1.8 for RGSS<3
} MKXPSyntaxTransformMode;

void                    mkxp_setSyntaxTransformMode(MKXPSyntaxTransformMode mode);
MKXPSyntaxTransformMode mkxp_getSyntaxTransformMode(void);

// Force the on-screen ABC grid for Pokemon Essentials text entry,
// overriding the iOS soft-keyboard path.
//
// The default soft-keyboard path works for IF / Reborn / Insurgence
// name entry, but a few games override the Essentials keyboard
// scene to add custom keys (mark, theme, etc.) that aren't on the
// iOS soft keyboard. Empo exposes a per-game toggle ("Use on-screen
// keyboard") that, when enabled, makes `pokemon_input.rb` re-apply
// the historical `USEKEYBOARDTEXTENTRY = false` +
// `PokemonEntryScene::USEKEYBOARD = false` overrides so the game
// uses its own ABC grid scene instead.
//
// Default = false (use the iOS soft keyboard).
void mkxp_setUseOnScreenKeyboard(bool enabled);
bool mkxp_getUseOnScreenKeyboard(void);

void        mkxp_setShowViewportBounds(bool enabled);
bool        mkxp_getShowViewportBounds(void);

// Cheat menu toggle (UI -> Engine).
//
// Setter sets the runtime cheat-enabled flag. The engine's postload
// layer reads the current value on each frame/update (Ruby-side code
// reassigns the $CHEATS global from the bridge so the UI toggle
// takes effect mid-game without re-entering the script).
void        mkxp_setCheatsEnabled(bool enabled);
bool        mkxp_getCheatsEnabled(void);

void        mkxp_setViewportBoundsColor(float r, float g, float b, float a);
void        mkxp_getViewportBoundsColor(float *r, float *g, float *b, float *a);

// Error routing (Engine -> UI)
//
// SDL_ShowSimpleMessageBox is a no-op on iOS, so errors are routed
// through the bridge for the UI to present.

void        mkxp_setErrorMessage(const char *message);

typedef void (*mkxp_ErrorMessageCallback)(const char *message, void *userdata);
void        mkxp_setErrorMessageCallback(mkxp_ErrorMessageCallback cb, void *userdata);

// Pause / Resume (UI <-> Engine)
//
// Flow:
//   1. UI calls mkxp_requestPause()
//   2. Engine calls mkxp_checkPause() from Graphics blocking points —
//      pauses audio, fires paused callback, blocks on condvar
//   3. UI calls mkxp_requestResume() to unblock

void        mkxp_requestPause(void);
void        mkxp_requestResume(void);

// Engine-internal: checks for pause request, blocks if needed. NOT for UI.
void        mkxp_checkPause(void);

bool        mkxp_isPauseRequested(void);
bool        mkxp_isPaused(void);

// Snapshot: RGBA pixel buffer captured before blocking.
void        mkxp_setSnapshot(const unsigned char *data, int width, int height);

// Copy the snapshot into `dest` (must be at least width*height*4 bytes).
// Returns true if a snapshot was available, false if empty.
bool        mkxp_copySnapshotRGBA(unsigned char *dest, int destSize, int *width, int *height);

// Returns the snapshot dimensions without copying. Use to pre-allocate
// the buffer for mkxp_copySnapshotRGBA.
bool        mkxp_getSnapshotSize(int *width, int *height);

// Fires on engine thread when paused (snapshot captured, audio suspended).
typedef void (*mkxp_PausedCallback)(void *userdata);
void        mkxp_setPausedCallback(mkxp_PausedCallback cb, void *userdata);

typedef void (*mkxp_ResumedCallback)(void *userdata);
void        mkxp_setResumedCallback(mkxp_ResumedCallback cb, void *userdata);

// One-shot: fires on engine thread after first frame is swapped post-resume
// (or fresh start). UI uses this to fade the snapshot / dismiss loading.
typedef void (*mkxp_FrameRenderedCallback)(void *userdata);
void        mkxp_setFrameRenderedCallback(mkxp_FrameRenderedCallback cb, void *userdata);

// Engine-internal: fires the one-shot frame-rendered signal. NOT for UI.
void        mkxp_signalFrameRendered(void);

// GL context crash detection (set by SDL layer on caught SIGSEGV/SIGBUS).

void        mkxp_setGLContextBroken(void);
bool        mkxp_isGLContextBroken(void);

// Debug logging

// Set log file path for this session (NULL/"" to disable).
void        mkxp_setDebugLogPath(const char *path);

// Append a tagged log line (no-op if disabled).
void        mkxp_debugLog(const char *tag, const char *source, const char *message);

// Fast-path predicate so hot-path callers can skip formatting the
// log message entirely when debug logging is off. Approximate: it
// may race with mkxp_setDebugLogPath but that's acceptable for a
// debug facility.
int         mkxp_debugLogEnabled(void);

#ifdef __cplusplus
}
#endif

#endif // IOS_BRIDGE_H
