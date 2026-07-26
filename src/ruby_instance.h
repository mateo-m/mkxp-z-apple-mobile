// ruby_instance.h - per-session Ruby VM instance manager.
//
// CRuby cannot be re-initialized against used VM globals: ruby_init
// assumes every interpreter global is in its untouched load-time
// state, and ruby_cleanup does not put them back. Cross-session play
// therefore never reuses a dirty VM. Instead, this manager mints a
// factory-fresh instance of the per-version Ruby "island" for every
// session:
//
//   1. dlclose/dlopen - the island ships as a standalone dylib
//      (RubyIsland<NN>.framework). Unloading and reloading the image
//      hands back pristine globals. Verified per retire with an
//      RTLD_NOLOAD canary; never assumed.
//   2. copy-and-load - when dyld refuses to unload the image, the
//      next session dlopens a byte-identical copy at a unique tmp
//      path (unlinked right after load, so no disk accumulation).
//      Distinct path -> distinct image -> fresh globals. The retired
//      image's memory stays resident; the host gates on available
//      memory while this mechanism is active.
//   3. static fallback - builds that still link the island's
//      merged.o directly get exactly one session per version per
//      process, and `mkxpi_sessionCapability` reports DIRTY after
//      it. This keeps pre-dylib builds working unchanged.
//
// Lifecycle (all on the RGSS thread, one session at a time):
//   acquire -> execute() -> retire. `mkxpi_currentScriptBinding()`
// serves mid-session terminate/reset dispatch (sharedstate.cpp,
// graphics.cpp) between those two points.
//
// The ScriptBinding vtable is the only pointer that may cross the
// island boundary into the host. Anything else retained across
// retire dangles once the image unloads.

#ifndef RUBY_INSTANCE_H
#define RUBY_INSTANCE_H

#include "app_bridge.h"

struct ScriptBinding;

#if MKXPZ_MOBILE

#ifdef __cplusplus
extern "C" {
#endif

// Mint (or check out) a fresh Ruby instance for `requested`. Follows
// the historical dispatcher's fallback order (requested, then 3.1,
// 1.9, 1.8) when the requested version isn't shipped. Also snapshots
// the process sigaction table; retire restores it, so Ruby's signal
// handlers never outlive the instance that installed them. Returns
// NULL when no fresh instance exists (the host should have gated on
// `mkxp_sessionCapability` before starting the session).
ScriptBinding *mkxpi_acquireRubyInstance(MKXPRubyVersion requested);

// The active session's binding, NULL outside acquire..retire.
ScriptBinding *mkxpi_currentScriptBinding(void);

// Retire the active instance: restore sigactions, dlclose, and run
// the unload canary that decides the next session's mechanism.
void mkxpi_retireRubyInstance(void);

// What a session for `version` would get right now. Safe from any
// thread; the Library UI polls it per game card.
MKXPSessionCapability mkxpi_sessionCapability(MKXPRubyVersion version);

// Human-readable state of the most recent acquire, e.g.
// "island 31 #3 (reset-in-place)". For the debug overlay via
// mkxp_getRubyInstanceDiagnostics(). Never NULL.
const char *mkxpi_rubyInstanceDiagnostics(void);

#ifdef __cplusplus
}
#endif

#else /* !MKXPZ_MOBILE */

// Desktop: single session per process on the statically-linked
// binding; the manager collapses to the legacy direct dispatch in
// binding.h and these stubs never run.
static inline ScriptBinding *mkxpi_acquireRubyInstance(MKXPRubyVersion requested) { (void)requested; return 0; }
static inline ScriptBinding *mkxpi_currentScriptBinding(void) { return 0; }
static inline void mkxpi_retireRubyInstance(void) {}
static inline MKXPSessionCapability mkxpi_sessionCapability(MKXPRubyVersion version) { (void)version; return MKXP_SESSION_CAP_FRESH; }
static inline const char *mkxpi_rubyInstanceDiagnostics(void) { return "single-session build"; }

#endif /* MKXPZ_MOBILE */

#endif // RUBY_INSTANCE_H
