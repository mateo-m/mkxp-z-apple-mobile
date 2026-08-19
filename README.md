# mkxp-z (Apple mobile fork)

> Fork of [mkxp-z](https://github.com/mkxp-z/mkxp-z) targeting iOS, iPadOS, and tvOS.

[![License](https://img.shields.io/badge/license-GPLv2%2B-blue.svg)](#license)
[![Upstream](https://img.shields.io/badge/upstream-mkxp--z-blue.svg)](https://github.com/mkxp-z/mkxp-z)

This fork powers [Empo](https://github.com/mateo-m/empo-app), the iOS and iPadOS RPG Maker player. Upstream mkxp-z does not target Apple mobile platforms. This fork now differs too much to merge back, but single fixes still go upstream as separate patches.

## Table of Contents

- [Background](#background)
- [Highlights](#highlights)
- [Layout](#layout)
- [Build](#build)
- [Contributing](#contributing)
- [License](#license)
- [Credits](#credits)

## Background

The original mkxp-z runs RPG Maker XP, VX, and VX Ace games on desktop Linux, macOS, and Windows. iOS adds limits that desktop builds never meet:

- An app cannot stop and restart itself between games. SDL, the GL context, OpenAL, and the running Ruby VM stay alive for the whole process.
- Apple made OpenGL ES obsolete in iOS 12, and the old EAGL path crashed on rotation. This fork therefore draws only through ANGLE, which runs OpenGL ES on top of Metal.
- App Store review rules do not let any code stop the process.
- RPG Maker games use four Ruby generations (1.8, 1.9, 3.0, 3.1), and one Ruby cannot run all of them.

This fork answers each of those. It also handles the usual Apple-platform problems: CAMetalLayer rotation, AVAudioSession timing, and screen-FBO capture for SwiftUI pause snapshots.

## Highlights

- **Three Ruby versions in one binary.** Ruby 1.8, 1.9, and 3.1 ship as merged `.o` files, one per version, with their symbols hidden so the copies cannot clash. The host picks one per game with `mkxp_setActiveRubyVersion()`. Old RGSS1 games run on real Ruby 1.8. Newer mkxp-z games run on 3.1, which also covers games built for Ruby 3.0.
- **Engine state stays alive.** SDL, the ANGLE EGL context, OpenAL, and the running Ruby VM last for the whole process. Every session reuses the same set of resources.
- **ANGLE drawing.** OpenGL ES on top of Metal. The old EAGL path is gone.
- **Syntax patches on Ruby 3.1.** The [PR #304](https://github.com/mkxp-z/mkxp-z/pull/304) patches let Pokemon Essentials games that mix 1.8 syntax with newer methods parse on Ruby 3.1. The host turns them on per game with `mkxp_setSyntaxTransformMode()`.
- **`src/app_bridge.h`.** A small C interface that the SwiftUI host calls for pause, resume, input, game paths, and similar session steps. The host never reaches into engine internals.
- **Clean exit.** `Kernel.exit!` and `Process.exit!` redirect to `Kernel.exit`, so the engine catches `SystemExit`. App Store rule 2.5.1 does not let code stop the process, so the engine raises a clean-exit flag and the host shows an alert instead.

## Layout

```text
binding/         Ruby C extension layer, compiled once per version
multiruby/       The one entry point each per-version merged object exports
src/             Engine core (graphics, audio, input, script bridge)
src/theoraplay/  Vendored ogg and theora decoder (upstream)
syntax-transform/3.1/   Ruby 3.1 parser patches for older grammar
scripts/         Ruby scripts that load before and after the game
hmode7/          H-Mode7 native port (git submodule)
tools/           Build recipes, dependency fetch, and test runners
tests/           C++ host tests, an in-engine RGSS suite, and its host
deps/            Prebuilt dependency libraries, fetched by a script
```

## Build

This repository owns both halves of the engine build. Each half is one script, and a host calls it:

| Script | Builds | Needs |
| --- | --- | --- |
| `tools/build-core-ios.sh` | `libmkxpz-core.a`, everything under `src/` | Dependency headers only |
| `tools/build-binding-ios.sh` | `mkxp<NN>-merged.o`, one per Ruby version | That version's libruby archives |

A host supplies the SDK, the dependency headers, and the libruby archives. It gets back artifacts that came out of these recipes at a public commit.

[empo-app](https://github.com/mateo-m/empo-app) includes this engine as a git submodule, calls both scripts, and links the result into a launcher. That is the only shipping app. See the empo-app README for those steps.

### Build and test on your own

This repository also builds a small app of its own, and that app runs
the in-engine suite. It needs no launcher:

```sh
tools/fetch-deps-ios.sh      # prebuilt dependency libraries, once
tools/run-engine-tests.sh    # builds the test host, then runs the suite
```

`tools/fetch-deps-ios.sh` downloads the pinned dependency release named
in `deps/.version` and checks its hash. `tools/build-test-host-ios.sh`
links the engine into `EngineTests.app` and puts the suite inside it.
`tools/run-engine-tests.sh` installs that app on a booted simulator and
reads the results back. The test host has no interface: it names its
own game folder and the engine boots it.

The C++ tests under `tests/cpp/` need none of this, not even the
dependencies. See [tests/README.md](tests/README.md).

This fork does not build for macOS, Linux, or Windows. The desktop code, the desktop build files (meson, platform Makefiles, the macOS Xcode project), and the desktop stand-ins are all removed. Use [upstream mkxp-z](https://github.com/mkxp-z/mkxp-z) for desktop.

## Contributing

Issues and PRs are welcome on [GitHub](https://github.com/mateo-m/mkxp-z-apple-mobile/issues). Most engine changes land together with a change in the [empo-app](https://github.com/mateo-m/empo-app) host. If you plan to change `src/app_bridge.h`, or anything else the host calls, open an issue first.

When you open a PR:

- Run `bun install` once so LeftHook installs the local hooks.
- Get a green build through the empo-app build pipeline.
- Match the code style around you. No formatter runs on this repo.
- Reference any related issue.

## License

[GPLv2+](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html), matching upstream.

## Credits

- The [mkxp-z contributors](https://github.com/mkxp-z/mkxp-z/graphs/contributors) and [Ancurio](https://github.com/Ancurio) for the original [mkxp](https://github.com/Ancurio/mkxp).
- [JoiPlay](https://github.com/joiplay) for the [Ruby 1.8 cross-compilation work](https://github.com/joiplay/ruby) and the multi-Ruby dispatch model.
- [white-axe](https://github.com/white-axe) for [PR #304](https://github.com/mkxp-z/mkxp-z/pull/304), the Ruby 3.1 syntax-transform patches.
