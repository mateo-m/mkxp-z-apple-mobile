# Raise tracing: the RAISETRACE log tag

## Why this exists

Some fangames hide the error that stops them. A repacked game frequently keeps its scripts as
loose `.rb` files and loads them with a small loader in `Scripts.rxdata`. The loader wraps each
`eval` in a `rescue` block that drops the exception. Pokemon Bushido is one example: its
`raise_traceback_error` has the `raise` lines commented out.

The result is a boot failure with no evidence. The loader swallows the error, the remaining
files still load, and script execution ends. The engine sees a normal end and reports a clean
exit, so the host shows "The game has ended or requested a restart." The debug log holds no
error at all.

Raise tracing solves this. The engine keeps the last exceptions in a ring buffer and writes
them to the debug log when script execution ends. A masked boot error becomes visible without
a [patch file](patches-format.md).

## How to use it

1. Turn on debug logs in the host app.
2. Start the game and reproduce the failure.
3. Open the session log and search for `RAISETRACE`.

The log is visible in the in-app Debug Logs view. It is also in the game's `Logs/` folder.

Output looks like this:

```text
[RAISETRACE] last 2 raise group(s), newest last
[RAISETRACE] NoMethodError: undefined method `tmpdir' for Dir:Class
[RAISETRACE]   from platform_compat:839
[RAISETRACE] RuntimeError:
WeakHardwareError:
Your GPU is too old to run the MKXP version of this game.
[RAISETRACE]   from 999_Main.rb:3:in `load_scripts_from_folder'
[RAISETRACE]   from 000:Main:28:in `eval'
```

Read the list from the bottom. The newest raise is last, and it is usually the one that stopped
the game.

## What the log shows

| Line                | Meaning                                                       |
| ------------------- | ------------------------------------------------------------- |
| `last N raise group(s)` | The buffer holds N groups. Older groups say how many dropped. |
| `<Class>: <message>`    | One raise. `[xN]` counts repeats of the same raise site.       |
| `from <frame>`          | One backtrace frame, indented. A group shows up to 10.        |

The buffer keeps 25 groups. It shortens messages after 300 characters.

Rescued exceptions appear too, and many are normal. The engine's own preload scripts probe for
optional methods and catch the failure. `Dir.tmpdir` in the example above is such a probe:
Ruby 1.8 needs `require 'tmpdir'` first, so the probe fails and the script uses `/tmp`. Treat a
`RAISETRACE` entry as evidence, not as proof of a defect.

## Limits

- The dump runs when script execution ends. A game that still runs has written nothing yet.
- A native crash stops the process before the dump. Use the crash report instead.
- The buffer keeps only the last 25 groups. Earlier raises are gone.

## How it works

Two parts, both active only when the host enables debug logs:

1. **The hook** (`binding/script-bootstrap.cpp`). The engine registers a C event hook for
   `RUBY_EVENT_RAISE`. The hook calls `MKXPRaiseTrace.record_exception` for every raise.
2. **The buffer** (`scripts/preload/raise_trace.rb`). The script stores, groups, and formats the
   entries. `binding/binding-mri.cpp` calls `drain` when script execution ends.

`RUBY_EVENT_RAISE` is the mechanism behind `TracePoint(:raise)`, and it exists on Ruby 1.8, 1.9
and 3.1. The hook therefore records VM-internal raises as well, such as a `NoMethodError` from a
typo. A Ruby-level `Kernel#raise` wrapper cannot do this, because the VM raises those errors
directly. Such errors are common, and a blanket `rescue` hides them.

The hook keeps the game's exception safe. It records under `rb_protect` and then restores the
pending exception. A failure in the recorder cannot replace what the game raises.

## References

- `binding/script-bootstrap.cpp`: the event hook and its registration
- `binding/binding-mri.cpp`: `drainRaiseTrace`, the end-of-session dump
- `scripts/preload/raise_trace.rb`: the ring buffer and the format
