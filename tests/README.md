# Tests

Two suites, split by what they need to run.

| Directory | Runs on | Needs |
| --- | --- | --- |
| `cpp/` | Your machine, in about a second | A C++ compiler |
| `engine/` | Inside a running engine | A simulator and the dependencies |
| `legacy-methods/` | Inside a running engine | The same, plus a Ruby on your machine |
| `host/` | - | It is what runs `engine/` and `legacy-methods/` |

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
| `ruby_compat.rb` | Behaviour every bundled interpreter must share. |
| `legacy_methods_off.rb` | The legacy methods stay away when the transform is off. |

Run it on a simulator with one command:

```sh
tools/run-engine-tests.sh
```

The script builds `EngineTests.app`, installs it on a booted
simulator, and prints the `[TEST]` lines the suite reports. It exits
non-zero when a check fails or when the suite never finishes. Pass
`--no-build` to reuse the last build, `--device <udid>` to pick a
simulator, and `--keep` to hold on to the console log.

`--suite <file>` runs another file in the same folder, and
`--ruby 18|19|31` picks the interpreter. The host reads both at
launch, so one build runs every suite on every interpreter. Add
`--no-build` to each run after the first:

```sh
tools/run-engine-tests.sh
for v in 18 19 31
do
    tools/run-engine-tests.sh --suite ruby_compat.rb --ruby "$v" --no-build
done
```

`--game` is the exception. That folder goes into the app bundle, so a
second folder needs a second build.

`ruby_compat.rb` is that suite. Each check there states a behaviour a
game gets on all three. It covers `$DEBUG` today: Ruby 1.8 and 1.9
bind that name to the interpreter's own debug flag, which makes
`sprintf` raise for a call that passes a spare argument, so
`binding/binding-mri.cpp` gives the name storage of its own.

Run `tools/fetch-deps-ios.sh` once first. It downloads the prebuilt
dependency libraries the engine links against.

`mkxp.json` names the suite to run in its `customScript` key. Change
that key to run another one, or pass `--suite`. The host copies the
folder out of the read-only bundle at launch and writes the key into
that copy, so the file in the repository keeps its own default. It
also sets `maxTextureSize`, which is how the mega suite reaches the
mega paths. See below.

Write that file as strict JSON. The engine reads JSON5 and would
accept comments and unquoted keys, but a host launcher may parse the
same file with a stricter reader to decide whether the folder is a
game.

Any other mkxp-z build can boot the same folder:

```sh
mkxp-z --gameFolder=/path/to/mkxp-z-apple-mobile/tests/engine
```

## Legacy methods

`legacy-methods/` covers the methods that Ruby 1.9 removed and that
`binding/binding-mri.cpp` defines again for the Ruby 3.1 build:
`Array#nitems`, `Array#choice`, `Object#id`, and the rest. Each one
runs only for a script that the syntax transform parsed, and raises
NoMethodError everywhere else.

The engine sets that flag on the sections of `Scripts.rxdata` alone,
so this folder is a game that boots from `Scripts.rxdata` rather than
from a `customScript`. Pack the file first:

```sh
ruby tests/legacy-methods/pack_scripts.rb
tools/run-engine-tests.sh --game tests/legacy-methods
```

`pack_scripts.rb` compresses `engine/harness.rb` and
`legacy-methods/legacy_methods.rb` into `legacy-methods/Data/`, which
git ignores. Edit the `.rb` files and pack again.

`engine/legacy_methods_off.rb` covers the other side. The transform
target is a whole-run setting, so with the transform off no script can
call these methods. The engine must then leave the names alone, because
a game tests for them with `Module#method_defined?` and installs its own
copy. `engine/` has no `syntaxTransform` key, which the engine reads as
off:

```sh
tools/run-engine-tests.sh --suite legacy_methods_off.rb --ruby 31
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
2. Calls `EngineTest.suite('<name>')`. Name it after the file, minus
   `.rb` and with every `_` written as `-`. `run-engine-tests.sh`
   compares the two after a `--suite` run, so a suite the host failed
   to select cannot report a clean pass.
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
