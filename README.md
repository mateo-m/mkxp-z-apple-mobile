# mkxp-z (Apple mobile fork)

> Fork of [mkxp-z](https://github.com/mkxp-z/mkxp-z) targeting iOS, iPadOS, and tvOS.

[![License](https://img.shields.io/badge/license-GPLv2%2B-blue.svg)](#license)
[![Upstream](https://img.shields.io/badge/upstream-mkxp--z-blue.svg)](https://github.com/mkxp-z/mkxp-z)

This fork powers [Empo](https://github.com/mateo-m/empo-app), the iOS / iPadOS RPG Maker player. Upstream mkxp-z doesn't target mobile Apple platforms; this fork has diverged enough that upstream convergence is no longer a goal, though individual fixes still land upstream as targeted patches.

## Highlights

- **Multi-Ruby native dispatch.** Four Ruby interpreters (1.8, 1.9, 3.0, 3.1) ship in the binary as per-version merged `.o` files with hidden symbol islanding. The host picks which one to dispatch to per-game via `mkxp_setActiveRubyVersion()`. Vintage RGSS1 games run on actual Ruby 1.8; modern mkxp-z forks run on 3.1.
- **Persistent engine state.** SDL, the ANGLE EGL context, OpenAL, and the active Ruby VM survive the entire process lifetime. iOS doesn't allow apps to kill themselves and respawn, so sessions reuse one set of resources.
- **ANGLE (OpenGL ES over Metal) only.** The legacy EAGL path was removed. It crashed on device rotation and Apple deprecated OpenGL ES in iOS 12.
- **Syntax-transform patches on Ruby 3.1.** Mixed-grammar Pokemon Essentials forks (1.8 syntax + 1.9+ runtime methods) parse on Ruby 3.1's VM with the [PR #304](https://github.com/mkxp-z/mkxp-z/pull/304) patches applied. Activated per-game via `mkxp_setSyntaxTransformMode()`.
- **`src/app_bridge.h`.** Small C ABI the SwiftUI host uses to drive the engine (pause, resume, inject input, swap game paths) without touching internals.
- **Apple-platform quirks handled.** CAMetalLayer rotation, iOS AVAudioSession coordination, screen-FBO capture timing for SwiftUI pause snapshots.

## Build

This engine is consumed as a git submodule by [empo-app](https://github.com/mateo-m/empo-app), which builds it via Xcode along with the app shell, dependency libraries, and packaging. **It does not build standalone.** Refer to the empo-app README for build instructions.

Desktop builds (macOS / Linux / Windows) are not supported. The desktop-specific code paths, build system files (meson, platform Makefiles, the macOS Xcode project), and platform shims have all been removed. Use [upstream mkxp-z](https://github.com/mkxp-z/mkxp-z) if you want desktop builds.

## Layout

```
binding/         Ruby C extension layer (per-version compiled)
src/             Engine core (graphics, audio, input, scripting bridge)
src/theoraplay/  Vendored ogg/theora decoder (upstream)
syntax-transform/3.1/   Ruby 3.1 parser patches for legacy grammar
scripts/         Ruby preload + postload shims
hmode7/          H-Mode7 native port (git submodule, see hmode7/README.md)
```

## License

[GPLv2+](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html), matching upstream.

## Credits

- The [mkxp-z contributors](https://github.com/mkxp-z/mkxp-z/graphs/contributors) and [Ancurio](https://github.com/Ancurio) for the original [mkxp](https://github.com/Ancurio/mkxp).
- [JoiPlay](https://github.com/joiplay) for the [Ruby 1.8 cross-compilation work](https://github.com/joiplay/ruby) and the multi-Ruby dispatch model.
- [white-axe](https://github.com/white-axe) for [PR #304](https://github.com/mkxp-z/mkxp-z/pull/304), the Ruby 3.1 syntax-transform patches.
