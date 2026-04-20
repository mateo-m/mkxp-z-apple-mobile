# mkxp-z (Apple mobile fork)

Fork of [mkxp-z](https://github.com/mkxp-z/mkxp-z) targeting iOS, iPadOS, and tvOS. This is the engine powering [Empo](https://github.com/mateo-m/empo-app). Upstream does not target mobile Apple platforms; this fork has diverged far enough that upstream convergence is no longer a goal, though individual fixes may still be offered upstream as targeted patches.

What this fork provides:

- **Persistent engine state** across game sessions. SDL, the ANGLE EGL context, OpenAL, and the Ruby VM all survive the main process for as long as the app is running, so sessions can be quit and relaunched without process restart.
- **ANGLE (OpenGL ES over Metal) only.** The legacy EAGL path was removed because it crashed on device rotation and Apple deprecated OpenGL ES in iOS 12.
- **Ruby 3.1 with syntax-transform patches** for game-script compatibility, and Ruby 1.8 still supported for RGSS1 titles.
- **`src/app_bridge.h`** - a small C ABI the SwiftUI host uses to drive the engine (pause, resume, inject input, swap game paths, etc.) without touching internals.
- **Apple-platform quirks handled** - CAMetalLayer rotation, cross-session alias/cvar/singleton-method cleanup in the persistent Ruby VM, iOS AVAudioSession coordination, screen-FBO capture timing, and so on.

## Building

This engine is consumed as a git submodule by [empo-app](https://github.com/mateo-m/empo-app), which builds it via Xcode along with the app shell, dependency libraries, and packaging. It does not build standalone. Refer to the empo-app README for build instructions.

Desktop builds (macOS / Linux / Windows) are **not supported** on this fork. The desktop-specific code paths, build system files (meson, platform Makefiles, Xcode project for macOS), and platform shims have all been removed. If you want desktop builds of mkxp-z, use [upstream mkxp-z](https://github.com/mkxp-z/mkxp-z) instead.

## License

GPLv2+, matching upstream.

## Credits

Everything that works here works because of the upstream [mkxp-z contributors](https://github.com/mkxp-z/mkxp-z/graphs/contributors), Ancurio for the original [mkxp](https://github.com/Ancurio/mkxp), and [JoiPlay](https://github.com/joiplay) for the Ruby 1.8 cross-compilation work.
