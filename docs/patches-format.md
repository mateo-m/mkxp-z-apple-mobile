# Script patches: patches.json

Empo can rewrite a game's RGSS scripts in memory as they load. JoiPlay-compatible
`patches.json` files drive the rewrite. A broken line in a fangame gets a targeted text
replacement. The patch does not change the game's own files and does not need an app rebuild.
The engine implementation is a port of JoiPlay's Patcher
(`src/patcher.{h,cpp}`).

This tool is for game developers and power users. Drop a `patches.json` next to `Game.ini`,
or list patch files in `mkxp.json` under `scriptPatches`.

## File format

```jsonc
{
  "rpgm": [{ "key": "<search text>", "value": "<replacement text>" }],
}
```

| Field   | Type   | Meaning                                                                        |
| ------- | ------ | ------------------------------------------------------------------------------ |
| `rpgm`  | array  | Rule list, applied in order. Required. The parser rejects the file without it. |
| `key`   | string | Text to find. A `[regex]` prefix switches to regex mode (below).               |
| `value` | string | Replacement text.                                                              |

Rules the parser applies (`Patcher::load` in `patcher.cpp`):

- The top-level value must be an object, and `rpgm` must be an array. If not, the parser
  rejects the whole file with a log line. The parser ignores other top-level keys.
- The parser silently skips array entries that are not objects, or that lack a string `key`
  **and** a string `value`.
- Encode multi-line search or replacement text with `\n` inside the JSON string. See the
  [worked example](#worked-example).

The engine parses patch files with json5pp (full JSON5: `//` and `/* */` comments, trailing
commas). See the host repo's
[config-format.md](https://github.com/mateo-m/empo-app/blob/main/docs/config-format.md) for
the parsing rules that Empo applies to config files.

## Matching semantics

**Literal (default).** Plain substring search. The patcher replaces every occurrence in the
script text. There is no anchoring and there are no word boundaries. An empty `key` never
matches.

**Regex.** When `key` starts with `[regex]`, the remainder compiles as a `std::regex` with
ECMAScript grammar and applies via `std::regex_replace`:

- The patcher replaces all matches, not only the first.
- `value` uses ECMAScript replacement syntax: `$&` for the whole match, `$1`…`$9` for capture
  groups. Write a literal dollar sign as `$$`.
- `.` does **not** match newlines. To span lines, use `[\s\S]`, usually with a lazy
  quantifier (`[\s\S]*?`). Then the match stops at the first terminator and does not swallow
  the rest of the script.
- Anchor carefully. When you replace a whole Ruby method, match the closing `end` at column 0
  (`\nend\b`). Then the regex cannot stop at an inner `if`/`end` and leave the outer `end`
  dangling. A dangling `end` produces a `SyntaxError` that skips the entire script section.

Rules run sequentially in load order. Each rule sees the output of the previous one, so a
later rule can rewrite text that an earlier rule produced (last writer wins).

## When patches apply

At engine boot, the engine decompresses the script archive (`Scripts.rxdata` / `.rvdata` /
`.rvdata2`). Each script section's source then passes through `Patcher::apply` immediately
before the engine hands it to the Ruby VM (`binding-mri.cpp`, `mriBindingExecute` script
loop). Consequences:

- **In-memory only.** The patcher never changes the game's files on disk, and saves stay
  compatible. If you remove a patch file, the game fully reverts on the next launch.
- **Every rule runs against every script section.** A literal `key` must be unique enough not
  to hit unrelated scripts.
- The patcher does **not** patch engine preload/postload scripts, only the game's own script
  sections.
- Scripts that a game loads by itself (external `.rb` files that a custom loader evals) do
  not pass through automatically. A loader can follow JoiPlay's convention: Pokémon Reborn's
  ScriptLoader pipes each file through `MKXP.apply_overrides(str)` before `eval`. This call
  applies the same rule list to arbitrary strings (`System.apply_overrides`, wrapped as
  `MKXP.apply_overrides` in `scripts/preload/mkxp_wrap.rb`). With no patches loaded, it
  returns the string unchanged.

## Where the engine finds patch files

The engine constructs `Patcher` once per session from `Config::scriptPatches`
(`src/patcher.cpp`, `src/config.cpp`):

1. **`scriptPatches` in `mkxp.json`**: an array of patch-file paths. Relative paths resolve
   against the game folder, the engine's working directory. When the array is non-empty, only
   these files load, and the engine skips auto-discovery entirely. This key is a fork
   addition. Upstream mkxp-z ignores it (see `src/config.h`). Do not confuse it with
   upstream's `patches` key, which mounts filesystem overlays.
2. **`<managed config dir>/patches.json`**: the per-game state directory that a host app can
   set via `mkxp_setManagedConfigDir` (`src/app_bridge.h`). Empo leaves this unset because
   the in-memory config overlay replaced the managed dir. So this tier never fires under
   Empo.
3. **`<game folder>/patches.json`**: the working directory, JoiPlay's historical location.
   Users can drop a patch file next to `Game.ini` without a config change.

The engine checks tiers 2 and 3 in order, and only the first file found loads. The tiers
never combine.

> **History.** In the past, Empo bundled a curated patch set (`PatcherDistribution` merged
> per-game rules into `EmpoState/patches.json`). Empo dropped it in July 2026. The config
> overlay change disconnected the delivery path, and the one curated rule (an Insurgence
> `getRegion` rewrite) had no player-visible effect. The engine Patcher above is unaffected.

## Failure behavior

Patching is best-effort and never aborts the boot:

| Failure                                              | Behavior                                         |
| ---------------------------------------------------- | ------------------------------------------------ |
| Patch file missing / unreadable                      | Logged, file skipped                             |
| JSON parse error                                     | Logged (exception message), file skipped         |
| Top-level not an object, or no `rpgm` array          | Logged, file skipped                             |
| Rule entry malformed (non-object, non-string fields) | Skipped silently                                 |
| Invalid regex in a `[regex]` key                     | Logged at apply time, rule skipped               |
| Rule matches nothing                                 | Silent no-op (the patcher logs only _changes_)   |
| Replacement produces invalid Ruby                    | `SyntaxError`, that script section fails to eval |

Diagnostics go through `patcherLog` to the session debug log with the `PATCHER` tag. The log
is visible in the in-app Debug Logs view and under the game's `Logs/` folder. Useful lines:

```text
loaded 1 patches from <path>
auto-discovered patches.json in managed dir <dir>
applied literal <key>
applied regex [regex]<pattern>
no explicit scriptPatches and no patches.json found in managed dir or cwd
```

If a rule you shipped has no `applied …` line, the rule never matched. Check whitespace and
line endings in the `key` against the actual script source.

## Worked example

Pokémon Insurgence's `getRegion` uses a Ruby-1.8 idiom (`.split('').map` without a block)
that crashes on Ruby 3. The method also derives its result from a Windows registry read that
does not exist on iOS. A patch that replaces the whole method with a locale-aware version
looks like this (abridged):

```jsonc
{
  "rpgm": [
    {
      "key": "[regex]def getRegion\\b[\\s\\S]*?\\nend\\b",
      "value": "def getRegion\n  lang = (System.user_language rescue \"en\").to_s\n  case lang[0..1]\n  when \"ja\" then return 1\n  when \"en\" then return 2\n  end\n  return 2\nend",
    },
  ],
}
```

Points to copy:

- `[\s\S]*?` (lazy) spans the method body across newlines, since `.` cannot.
- `\nend\b` pins the match to an `end` at column 0, so an inner `if`/`end` cannot terminate
  the match early and leave broken syntax behind.
- The replacement is a complete, self-contained method with `\n`-encoded newlines. After the
  substitution, the script section must still be valid Ruby.

## References

- `src/patcher.h`, `src/patcher.cpp`: format, matching, discovery
- `src/config.h`, `src/config.cpp`: the `scriptPatches` key
- `binding/binding-mri.cpp`: apply site, `System.apply_overrides`
- `scripts/preload/mkxp_wrap.rb`: the `MKXP.apply_overrides` shim
- [config-format.md](https://github.com/mateo-m/empo-app/blob/main/docs/config-format.md) in
  the host repo: the parsing rules for config files
