# Tests

Two suites, split by what they need to run.

| Directory | Runs on | Needs |
| --- | --- | --- |
| `cpp/` | Your machine, in about a second | A C++ compiler |
| `engine/` | Inside a running engine | A simulator and the dependencies |
| `host/` | - | It is what runs `engine/` |

Neither suite needs a launcher. `cpp/` needs nothing but this
repository.

## C++ tests

`cpp/` covers engine code that takes bytes and returns bytes. No
window, no GPU, no Ruby. It compiles the sources under test straight
from `src/`, so there is no library to build first.

```sh
tools/run-cpp-tests.sh
```

The script hides the engine's own stderr output unless a check fails.
Pass `--verbose` to see it anyway, or `--keep` to leave the binary in
place for a debugger.

To cover another file, write a `cpp/test_<name>.cpp` and add the
source to `ENGINE_SOURCES` in the script. `TEST(name)` registers a
case by itself, so no list needs an edit. Keep out anything that
pulls in SDL, PhysFS, or the Ruby binding. Those need the full engine
build, and they belong in `engine/` instead.

## In-engine tests

`engine/` is a game folder. The engine boots it the way it boots any
game, which is the only way to reach the drawing code.

| File | Purpose |
| --- | --- |
| `harness.rb` | Assertions and result reporting. |
| `mkxp.json` | Config that turns the folder into a game. |
| `mega_bitmap.rb` | Mega-surface suite. |

Run it on a simulator with one command:

```sh
tools/run-engine-tests.sh
```

The script builds `EngineTests.app`, installs it on a booted
simulator, and prints the `[TEST]` lines the suite reports. It exits
non-zero when a check fails or when the suite never finishes. Pass
`--no-build` to reuse the last build, `--device <udid>` to pick a
simulator, and `--keep` to hold on to the console log.

Run `tools/fetch-deps-ios.sh` once first. It downloads the prebuilt
dependency libraries the engine links against.

`mkxp.json` names the suite to run in its `customScript` key. Change
that key to run another one. It also sets `maxTextureSize`, which is
how the suite reaches the mega paths. See below.

Write that file as strict JSON. The engine reads JSON5 and would
accept comments and unquoted keys, but a host launcher may parse the
same file with a stricter reader to decide whether the folder is a
game.

Any other mkxp-z build can boot the same folder:

```sh
mkxp-z --gameFolder=/path/to/mkxp-z-apple-mobile/tests/engine
```

## The test host

`host/` is the app that runs `engine/`. It is a shim, not a launcher:
one file that names a game folder and gets out of the way.

The engine's `main()` waits in `mkxp_waitForGamePath()` until a host
answers. A launcher answers when a person taps a game. This host
answers with the folder it copied out of its own bundle, and the
engine boots it like any game.

`tools/build-test-host-ios.sh` builds the app without Xcode. An iOS
app bundle is a directory with a binary, an `Info.plist`, and
resources, so the script compiles the shim, links it against the
engine, fills the bundle, and signs it ad hoc.

WARNING: the shim writes no bridge state from its constructor. That
constructor runs before the C++ static initializers in
`src/app_bridge.cpp`, and those wipe anything written first. The
constructor queues the work on the main queue instead, where
`mkxp_waitForGamePath` runs it while it waits.

## Reading the results

Both suites print the same line grammar. Every line starts with a
`[TEST]` tag:

```text
[TEST] SUITE mega-bitmap
[TEST] INFO max_size=2048
[TEST] ok small: clear empties the whole bitmap
[TEST] PEND mega: blur softens an edge -- Operation not supported for mega surfaces
[TEST] FAIL small: blt copies a source rect into place -- first copied pixel at [4, 4]: expected [255, 0, 0, 255], got [0, 255, 0, 255]
[TEST] DONE passed=33 failed=0 pending=11
```

`PEND` comes from the in-engine suites only. It means the engine
refused the operation with a known "not supported" error. Treat it as
a to-do, not a defect: the suite states what the operation should do,
and the engine does not do it yet. When the engine gains the
operation, the line becomes `ok` on its own.

A suite prints one line per check. Compare a run before a change with
a run after it, and `diff` shows what moved.

## Mega surfaces

A bitmap too large for one GPU texture stays in main memory as an
SDL surface. Every drawing operation then needs a second
implementation that works on the CPU, and those are the paths the
mega suite covers.

The suites do not build huge bitmaps to reach those paths. They set
`maxTextureSize` in `mkxp.json` instead, which lowers the size at
which the engine switches to a mega surface. Keep that value above
the screen size. Below it, ordinary rendering starts taking the mega
paths too, and a failure no longer says which path broke.

## Writing an in-engine suite

Start from `mega_bitmap.rb`. A suite:

1. Loads the harness on its first lines. The engine skips
   `preloadScript` for a game that boots from a `customScript`, so
   each suite loads the harness itself.
2. Calls `EngineTest.suite('<name>')`.
3. Wraps each check in `EngineTest.test('<name>') { ... }`.
4. Ends with `EngineTest.finish` and `exit`.

`mega_bitmap.rb` runs every check against two kinds of bitmap, so it
registers the checks with a local `check` helper first and runs the
list once per kind. A suite with nothing to vary can call
`EngineTest.test` directly.

Write each check so it passes on an ordinary bitmap today. Let the
harness report `PEND` for the paths the engine has not implemented:
do not delete the check, and do not write it to expect the error.

The suites must parse on Ruby 1.8, 1.9, and 3.x, because the engine
picks the interpreter per game.

## Credit

`mega_bitmap.rb` covers the same operations as
`tests/mega-bitmap/mega-bitmap-test.rb` in upstream mkxp-z, by
Splendide Imaginarius (GPLv2+). The checks were rewritten to assert
their results instead of writing images for a person to compare.
