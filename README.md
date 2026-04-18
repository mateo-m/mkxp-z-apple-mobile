# mkxp-z (Apple mobile fork)

Fork of [mkxp-z](https://github.com/mkxp-z/mkxp-z) with the iOS- and iPadOS-specific changes needed to embed the engine inside [Empo](https://github.com/mateo-m/empo-app). Upstream does not target mobile Apple platforms, so this branch carries patches that:

- Keep SDL, the GL context, OpenAL, and the Ruby VM alive across multiple game sessions (iOS can't relaunch the app mid-process).
- Cross-compile Ruby 1.8 from [JoiPlay's fork](https://github.com/joiplay/ruby) for RGSS1 compatibility.
- Expose a small C bridge (`src/app_bridge.h`) so a SwiftUI host can drive the engine without touching its internals.
- Work around Apple-specific quirks - FBO 0 isn't the screen, `alcMakeContextCurrent` must run on the main thread, Ruby 1.8's 512 KB pthread stack is too small, and so on.

The goal is to stay as close to upstream as possible and rebase onto it when it makes sense.

## Building

For iOS/iPadOS, this engine is consumed as a git submodule by [empo-app](https://github.com/mateo-m/empo-app), which handles dependency builds, Xcode project generation, and packaging. See the empo-app README.

Desktop builds are currently broken on this fork:

- **macOS via meson** was already disabled upstream (use their Xcode project).
- **Linux and Windows** still have the upstream `meson.build`, but the new source files we added (`src/app_bridge.cpp`, `src/display/movie.cpp`, etc.) aren't registered in `src/meson.build`, so linking would fail. Fixing it is doable - add the missing files and guard the iOS-only ones with `#if TARGET_OS_IPHONE` - but it isn't done yet.

If you want the desktop builds, [upstream mkxp-z](https://github.com/mkxp-z/mkxp-z) is the place to go.

## License

GPLv2+, matching upstream.

## Credits

Everything that works here works because of the upstream [mkxp-z contributors](https://github.com/mkxp-z/mkxp-z/graphs/contributors), Ancurio for the original [mkxp](https://github.com/Ancurio/mkxp), and [JoiPlay](https://github.com/joiplay) for the Ruby 1.8 cross-compilation work.
