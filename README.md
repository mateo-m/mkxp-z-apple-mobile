# mkxp-z (Apple mobile fork)

> Fork of [mkxp-z](https://github.com/mkxp-z/mkxp-z) targeting iOS, iPadOS, and tvOS.

[![License](https://img.shields.io/badge/license-GPLv2%2B-blue.svg)](#license)
[![Upstream](https://img.shields.io/badge/upstream-mkxp--z-blue.svg)](https://github.com/mkxp-z/mkxp-z)

This fork powers [Empo](https://github.com/mateo-m/empo-app), the iOS / iPadOS RPG Maker player. Upstream mkxp-z doesn't target mobile Apple platforms; this fork has diverged enough that upstream convergence is no longer a goal, though individual fixes still land upstream as targeted patches.

## Table of Contents

- [Background](#background)
- [Highlights](#highlights)
- [Layout](#layout)
- [Build](#build)
- [Contributing](#contributing)
- [License](#license)
- [Credits](#credits)

## Background

The original mkxp-z runs RPG Maker XP / VX / VX Ace games on desktop Linux, macOS, and Windows. iOS adds constraints that desktop builds never have to think about:

- Apps can't kill themselves and respawn between games. SDL, the GL context, OpenAL, and the active Ruby VM stay alive for the entire process lifetime.
- Apple deprecated OpenGL ES in iOS 12 and the legacy EAGL path crashed on rotation, so this fork renders through ANGLE (OpenGL ES on top of Metal) exclusively.
- App Store review rules forbid programmatic process termination anywhere in the codebase.
- RPG Maker games span four Ruby generations (1.8, 1.9, 3.0, 3.1) and a single host Ruby can't cover all of them.

This fork addresses each of those plus the usual Apple-platform quirks (CAMetalLayer rotation, AVAudioSession coordination, screen-FBO capture timing for SwiftUI pause snapshots).

## Highlights

- **Multi-Ruby native dispatch.** Four Ruby interpreters (1.8, 1.9, 3.0, 3.1) ship in the binary as per-version merged `.o` files with hidden symbol islanding. The host picks which one to dispatch to per game via `mkxp_setActiveRubyVersion()`. Vintage RGSS1 games run on actual Ruby 1.8; modern mkxp-z forks run on 3.1.
- **Persistent engine state.** SDL, the ANGLE EGL context, OpenAL, and the active Ruby VM survive the entire process lifetime. Sessions reuse one set of resources.
- **ANGLE rendering.** OpenGL ES over Metal. The legacy EAGL path was removed.
- **Syntax-transform patches on Ruby 3.1.** Mixed-grammar Pokemon Essentials forks (1.8 syntax + 1.9+ runtime methods) parse on Ruby 3.1's VM with the [PR #304](https://github.com/mkxp-z/mkxp-z/pull/304) patches applied. Activated per game via `mkxp_setSyntaxTransformMode()`.
- **`src/app_bridge.h`.** Small C ABI that the SwiftUI host calls into for pause, resume, input injection, game-path handoff, and similar lifecycle operations. The host never touches engine internals.
- **Clean exit handling.** `Kernel.exit!` and `Process.exit!` redirect to `Kernel.exit` so the engine catches `SystemExit`. App Store guideline 2.5.1 forbids programmatic process termination, so the engine sets a clean-exit flag and the host shows an alert instead of killing the process.

## Layout

```
binding/         Ruby C extension layer (per-version compiled)
src/             Engine core (graphics, audio, input, scripting bridge)
src/theoraplay/  Vendored ogg/theora decoder (upstream)
syntax-transform/3.1/   Ruby 3.1 parser patches for legacy grammar
scripts/         Ruby preload + postload shims
hmode7/          H-Mode7 native port (git submodule)
```

## Build

This engine is consumed as a git submodule by [empo-app](https://github.com/mateo-m/empo-app), which builds it via Xcode along with the app shell, dependency libraries, and packaging. **It does not build standalone.** Refer to the empo-app README for build instructions.

Desktop builds (macOS / Linux / Windows) are not supported. Desktop-specific code paths, build system files (meson, platform Makefiles, the macOS Xcode project), and platform shims have all been removed. Use [upstream mkxp-z](https://github.com/mkxp-z/mkxp-z) for desktop.

## Contributing

Issues and PRs welcome on [GitHub](https://github.com/mateo-m/mkxp-z-apple-mobile/issues). Most engine-level changes happen in lockstep with the [empo-app](https://github.com/mateo-m/empo-app) host; coordinate through an issue first if you're proposing a change to `src/app_bridge.h` or anything else that crosses the host boundary.

When opening a PR:

- Run `bun install` once so LeftHook installs the local hooks.
- Build green via the empo-app build pipeline.
- Match the existing code style; no formatter is enforced.
- Reference any related issue.

## License

[GPLv2+](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html), matching upstream.

## Credits

- The [mkxp-z contributors](https://github.com/mkxp-z/mkxp-z/graphs/contributors) and [Ancurio](https://github.com/Ancurio) for the original [mkxp](https://github.com/Ancurio/mkxp).
- [JoiPlay](https://github.com/joiplay) for the [Ruby 1.8 cross-compilation work](https://github.com/joiplay/ruby) and the multi-Ruby dispatch model.
- [white-axe](https://github.com/white-axe) for [PR #304](https://github.com/mkxp-z/mkxp-z/pull/304), the Ruby 3.1 syntax-transform patches.
