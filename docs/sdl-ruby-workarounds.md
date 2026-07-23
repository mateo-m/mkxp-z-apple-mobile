# SDL and Ruby lifecycle workarounds

## Why this exists

The iOS port of mkxp-z keeps SDL, the GL context, OpenAL, and the active Ruby VM alive for the process lifetime. Two constraints drove the architecture:

1. **SDL cannot restart** - the design of `SDL_Init`/`SDL_Quit` and window creation assumes a single process lifetime.
2. **Ruby cannot restart** - `ruby_init()` and `ruby_cleanup()` are one-shot operations. A call to `ruby_cleanup()` destroys the VM, and a later `ruby_init()` crashes. The cause: Ruby's `Init_*` functions stash VALUEs in file-scope statics that do not reset.

These constraints affect every layer of the architecture. Cross-session play (multiple games in sequence in one process) is behind a feature flag. See the host-side doc [multi-session.md](https://github.com/mateo-m/empo-app/blob/main/docs/multi-session.md). The persistent-resource architecture below still applies: the active Ruby and SDL stay alive even though we no longer swap games.

---

## 1. Persistent SDL window, ANGLE EGL context, and OpenAL device

**Problem:** SDL creates a window on `SDL_Init`. If the engine destroys and recreates the window between game sessions, GL context issues occur on iOS.

**Solution (`main.cpp`):** The engine creates the SDL window, the ANGLE EGL context, and the OpenAL device **once**, and reuses them across all game sessions. iOS uses only ANGLE (OpenGL ES over Metal). We removed the legacy EAGL/OpenGL ES path for two reasons: it crashed on device rotation because of a threading race in SDL's `CAEAGLLayer` renderbuffer reallocation, and Apple deprecated OpenGL ES in iOS 12.

```cpp
// Created once, persist for the process lifetime
SDL_Window *persistWin = SDL_CreateWindow(...);  // no SDL_WINDOW_OPENGL - ANGLE uses a plain CALayer
initANGLE(persistWin);  // sets up s_eglDisplay / s_eglSurface / s_eglContext
ALCdevice *persistAlcDev = alcOpenDevice(0);
ALCcontext *persistAlcCtx = alcCreateContext(persistAlcDev, 0);
```

At the end of each session, the engine **detaches** the EGL and AL contexts from the RGSS thread. It does not destroy them. The next session's thread can then claim them:

```cpp
// Don't destroy - just detach from the dying thread
alcMakeContextCurrent(NULL);
eglMakeCurrent(s_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
```

### Screen FBO capture

The engine captures the screen FBO once, directly after `initANGLE()`, and reuses it forever. Under ANGLE/Metal, the value is usually 0. We never query `GL_FRAMEBUFFER_BINDING` again in later sessions because `SharedState::finiInstance` deleted all game FBOs by then.

```cpp
static GLuint s_screenFBO = 0;
// Captured once in initANGLE:
glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
s_screenFBO = static_cast<GLuint>(fbo);
```

---

## 2. The `while(true)` game session loop

**Problem:** SDL and Ruby cannot restart, so the engine cannot exit `main()` and enter it again.

**Solution (`main.cpp`):** A `while(true)` loop on the main thread manages game sessions. Each iteration spawns a new RGSS thread for the game, waits for it to finish, then loops back to wait for the next game selection.

```text
main thread:  SDL_Init → create window → while(true) { wait for game → spawn RGSS thread → wait for thread → cleanup → continue }
RGSS thread:  load game → run Ruby → exit thread
```

Between sessions, the engine:

- Flushes stale SDL events, especially `SDL_QUIT` from the previous session
- Zeroes all input state arrays
- Clears the framebuffer to black so the last frame does not flash
- Resets bridge state

---

## 3. Ruby VM kept alive across sessions

**Problem (`binding-mri.cpp`):** A call to `ruby_cleanup()` destroys the VM struct but leaves dangling static C pointers in extension `Init_*` functions (for example, `Init_String` stashes class VALUEs in file-scope statics). A later `ruby_init()` crashes in `rb_call_inits`. This is a known upstream Ruby limitation.

**Solution:** The engine initializes the active Ruby VM **once** and keeps it alive for the process lifetime. `mriBindingExecute` splits into two parts:

- `InitOnce` - `ruby_init`, `topSelf` registration, runs once per process.
- `PerSession` - `mriBindingInit`, script execution, runs every session to reinstall C methods on top of game-script redefinitions.

With multi-Ruby ([multi-ruby.md](https://github.com/mateo-m/empo-app/blob/main/docs/multi-ruby.md) in the host repo), the binary contains three Ruby builds, but only one is active per process: the one that detection picked for the first selected game. A switch to a different Ruby version mid-process is not supported because the chosen version's `ruby_init` already ran.

The historical `resetBetweenSessions()` cleanup (constant-baseline diffing, singleton-method scrubbing, the `$mouse` shim, RGSS disposable detachment) is dormant because cross-session play is disabled. Same-session reset hooks (`$__mkxp_reset_hooks`, a GC cycle, etc.) still fire if a game raises `Reset` mid-play, because the user stays in the same game.

---

## 4. Run loop pumping while waiting

**Problem (`app_bridge.cpp`):** `SDL_main` runs on the main thread on iOS. While the engine waits for the user to select a game from the Library UI, UIKit must still render and handle events.

**Solution:** The wait loop pumps `CFRunLoop` manually:

```cpp
while (!s_pathSet.load(std::memory_order_acquire)) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
}
```

This keeps UIKit alive, so it renders the SwiftUI Library while the C++ engine blocks on the main thread.

---

## 5. Callback-based state notification

**Problem:** The SwiftUI Library UI and the C++ engine communicate through a C bridge (`app_bridge.h`). The UI must know when the engine changes state (first frame rendered, viewport rect changed, engine terminated).

**Solution (`AppState.swift`, `app_bridge.cpp`):** The bridge provides callback registration functions. The UI registers the callbacks once at init. Callbacks fire on the engine thread, and Swift dispatches to the main thread for UI updates.

```swift
// Registered once in AppState.init()
mkxp_setFrameRenderedCallback({ _ in
    DispatchQueue.main.async {
        // First frame: transition from .loading to .playing
        // Resume: signal snapshot can fade
    }
}, nil)

mkxp_setEngineTerminatedCallback({ _ in
    DispatchQueue.main.async { GameLibrary.shared.reload() }
}, nil)

mkxp_setGameRectChangedCallback({ x, y, w, h, _ in
    DispatchQueue.main.async { EngineState.shared.gameRect = CGRect(...) }
}, nil)
```

The engine calls these callbacks at the correct points. The rect callback fires only when the value changes.

---

## 6. Engine termination via SDL_QUIT injection

**Problem:** There is no direct "kill engine" function. The engine runs its own event loop.

**Solution:** To quit, the app pushes `SDL_QUIT` into SDL's event queue. The engine's event loop picks it up and starts a normal shutdown:

```cpp
void mkxp_requestTerminate(void) {
    SDL_Event event;
    event.type = SDL_QUIT;
    SDL_PushEvent(&event);
}
```

---

## 7. Ruby timing compatibility (`Graphics.delta`)

**Problem (`graphics.cpp`):** Some Pokemon fangames with mkxp-era compatibility shims treat Ruby's `Graphics.delta` as **microseconds**, then derive seconds themselves. Pokemon Vanguard does this in `001_MKXP_Compatibility.rb`:

```ruby
def self.delta_s
  self.delta.to_f / 1_000_000
end
```

Empo's engine-side timing uses seconds internally (`SharedState::runTime()`, frame pacing, transition timers). An earlier binding exposed that same seconds value directly to Ruby. That made `Graphics.delta_s` collapse to ~0. Vanguard's battle intro transition timer never advanced, and `Graphics.transition` spun forever.

**Solution (`src/display/graphics.cpp`):** Keep the engine's internal timing in seconds. Convert the Ruby-visible `Graphics.delta` value back to mkxp-compatible microseconds at the binding boundary. This keeps the engine's pacing semantics and matches what legacy Pokemon compatibility layers expect.

This fix is narrow on purpose: only the Ruby-facing `Graphics.delta` contract changed. Internal update/blit timing still runs on seconds-based deltas.

---

## 8. AppWindow layering above SDL

**Problem:** SDL creates its own `UIWindow` with an OpenGL view. The SwiftUI Library UI must appear above it. The Player controls must overlay it and pass non-control touches through.

**Solution (`AppWindow.swift`):** The app creates a single `UIWindow` at `windowLevel = .normal + 1`, above SDL's window, and installs it via `+load` before `main()` runs. The window switches between opaque (Library mode) and transparent (Player mode). The app observes theme changes (dark/light/auto) via `withObservationTracking` and applies them at the window level via `overrideUserInterfaceStyle`.

---

## Summary

| Constraint                                         | Workaround                                                       |
| -------------------------------------------------- | ---------------------------------------------------------------- |
| SDL can't restart                                  | Persistent window/EGL/AL, session loop                           |
| Ruby can't restart                                 | Keep VM alive, reset state between sessions                      |
| Some games expect `Graphics.delta` in microseconds | Keep engine timing in seconds, expose Ruby delta in microseconds |
| Main thread blocked by SDL                         | Pump CFRunLoop manually                                          |
| No C++→Swift callbacks                             | C function pointer callbacks (dispatch to main)                  |
| No direct engine kill                              | Inject SDL_QUIT event                                            |
| SDL owns a UIWindow                                | Float SwiftUI window above it                                    |
