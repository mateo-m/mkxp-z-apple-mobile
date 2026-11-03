#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Build the test host, run the in-engine suite on a simulator, and
# report what it found.
#
# The suite needs a running engine: a GPU, a window, and a Ruby VM.
# That is what makes it different from tests/cpp, which needs only a
# compiler. It still needs no person and no launcher.
#
# Usage:
#   tools/run-engine-tests.sh [--device <name or udid>] [--game <dir>]
#                             [--suite <file> ...] [--ruby 18|19|31]
#                             [--fast-forward <n>]
#                             [--timeout <seconds>] [--keep] [--no-build]
#
# --suite names another file in the game folder to run in place of
# the one mkxp.json points at. The suite must call
# EngineTest.suite with its own file name, minus ".rb" and with
# every "_" written as "-". This script compares the two, so a
# selection the host dropped cannot pass as a clean run. Give
# --suite more than once to run several suites in one launch, in that
# order. The game folder then needs run_suites.rb. Each suite can
# appear only once.
#
# --game picks a game folder. With --no-build, the last build must
# hold a folder of the same name. The harness prints the folder the
# host opened, and this script compares it to the one asked for.
#
# --ruby picks the interpreter the suite runs on. Without it the
# engine keeps its own default.
#
# --fast-forward sets the engine's fast-forward multiplier.
#
# Exit status:
#   0  every test passed
#   1  at least one test failed, or the suite never finished
#   2  bad usage or a missing prerequisite
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"

DEVICE=""
GAME="$ENGINE/tests/engine"
TIMEOUT=180
SUITES=""
RUBY=""
FAST_FORWARD=""
KEEP=0
BUILD=1
BUNDLE_ID=sh.mateo.mkxpz.enginetests
CONSOLE=""

# The name a suite file gives to EngineTest.suite.
suite_name() {
    printf '%s' "${1%.rb}" | tr '_' '-'
}

while [ "$#" -gt 0 ]
do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --game) GAME="$2"; shift 2 ;;
        --suite)
            for seen in $SUITES
            do
                if [ "$(suite_name "$seen")" = "$(suite_name "$2")" ]; then
                    echo "run-engine-tests: --suite $2 is given twice" >&2
                    exit 2
                fi
            done
            SUITES="$SUITES $2"; shift 2 ;;
        --ruby)
            case "$2" in
                18|19|31) ;;
                *) echo "run-engine-tests: --ruby takes 18, 19 or 31, not $2" >&2; exit 2 ;;
            esac
            RUBY="$2"; shift 2 ;;
        --fast-forward) FAST_FORWARD="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --no-build) BUILD=0; shift ;;
        *) echo "run-engine-tests: unknown argument $1" >&2; exit 2 ;;
    esac
done

cleanup() {
    [ "$KEEP" = "1" ] && return 0
    [ -n "$CONSOLE" ] && rm -f "$CONSOLE"
    return 0
}
trap cleanup EXIT INT TERM

if ! xcrun simctl help >/dev/null 2>&1; then
    echo "run-engine-tests: simctl not available. Install Xcode." >&2
    exit 2
fi

# --- Pick a simulator -------------------------------------------------
if [ -z "$DEVICE" ]; then
    # Prefer one that is already booted, so a repeated run costs
    # nothing. Otherwise take the newest available iPhone.
    DEVICE="$(xcrun simctl list devices available booted \
        | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -n 1)"
fi
if [ -z "$DEVICE" ]; then
    DEVICE="$(xcrun simctl list devices available \
        | grep -E '^ +iPhone' | tail -n 1 \
        | sed -n 's/.*(\([0-9A-F-]\{36\}\)).*/\1/p')"
fi
if [ -z "$DEVICE" ]; then
    echo "run-engine-tests: no available iPhone simulator found" >&2
    exit 2
fi

NAME="$(xcrun simctl list devices | grep "$DEVICE" | sed -e 's/^ *//' -e 's/ *(.*//' | head -n 1)"
echo "run-engine-tests: using $NAME ($DEVICE)"

# --- Build ------------------------------------------------------------
GAME="$(cd "$GAME" && pwd)"
GAME_NAME="${GAME##*/}"
SUITE_COUNT=0
for suite in $SUITES
do
    if [ ! -f "$GAME/$suite" ]; then
        echo "run-engine-tests: $GAME/$suite missing" >&2
        exit 2
    fi
    SUITE_COUNT=$((SUITE_COUNT + 1))
done
if [ "$SUITE_COUNT" -gt 1 ] && [ ! -f "$GAME/run_suites.rb" ]; then
    echo "run-engine-tests: several suites need $GAME/run_suites.rb" >&2
    exit 2
fi

APP="$ENGINE/build/iphonesimulator-arm64/EngineTests.app"

if [ "$BUILD" = "1" ]; then
    "$ENGINE/tools/build-test-host-ios.sh" --game "$GAME"
fi

if [ ! -d "$APP/Games/$GAME_NAME" ]; then
    echo "run-engine-tests: $APP/Games/$GAME_NAME missing. Drop --no-build." >&2
    exit 2
fi

xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true

# --- Install ----------------------------------------------------------
# Reinstall only a changed build. The host clears Documents at each
# launch, so an app that stays installed starts from the same state.
INSTALLED="$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true)"
if [ -n "$INSTALLED" ] && diff -rq "$APP" "$INSTALLED" >/dev/null 2>&1; then
    echo "run-engine-tests: the installed app matches the build"
else
    xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
    if ! xcrun simctl install "$DEVICE" "$APP"; then
        echo "run-engine-tests: install failed" >&2
        exit 1
    fi
fi

# --- Run --------------------------------------------------------------
CONSOLE="$(mktemp "${TMPDIR:-/tmp}/mkxpz-engine-tests.XXXXXX")"

echo "run-engine-tests: launching $GAME_NAME${SUITES:+ with$SUITES}${RUBY:+ on Ruby $RUBY}..."
export SIMCTL_CHILD_MKXP_TEST_GAME="$GAME_NAME"
if [ -n "$RUBY" ]; then
    export SIMCTL_CHILD_MKXP_TEST_RUBY="$RUBY"
fi
if [ "$SUITE_COUNT" -gt 1 ]; then
    export SIMCTL_CHILD_MKXP_TEST_SUITE=run_suites.rb
    export SIMCTL_CHILD_MKXP_TEST_SUITES="${SUITES# }"
elif [ "$SUITE_COUNT" = 1 ]; then
    export SIMCTL_CHILD_MKXP_TEST_SUITE="${SUITES# }"
fi
if [ -n "$FAST_FORWARD" ]; then
    export SIMCTL_CHILD_MKXP_TEST_FAST_FORWARD="$FAST_FORWARD"
fi
xcrun simctl launch --console-pty "$DEVICE" "$BUNDLE_ID" > "$CONSOLE" 2>&1 &
LAUNCH_PID=$!

# The suite ends with `exit`, which ends the process, but a crash or a
# hang would leave the launch running forever. Poll for one DONE line
# per suite and give up after the timeout.
WANT_DONE=1
[ "$SUITE_COUNT" -gt 1 ] && WANT_DONE="$SUITE_COUNT"
WAITED=0
while [ "$WAITED" -lt "$TIMEOUT" ]
do
    if [ "$(grep -ac '^\[TEST\] DONE' "$CONSOLE" 2>/dev/null || true)" -ge "$WANT_DONE" ]; then
        break
    fi
    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

kill "$LAUNCH_PID" 2>/dev/null || true
xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true

# --- Report -----------------------------------------------------------
if [ "$KEEP" = "1" ]; then
    echo "run-engine-tests: console log kept at $CONSOLE"
fi

RESULTS="$(grep -a '^\[TEST\]' "$CONSOLE" | tr -d '\r' || true)"
printf '%s\n' "$RESULTS"

field() {
    printf '%s\n' "$2" | sed -n "s/.*$1=\([0-9][0-9]*\).*/\1/p"
}

# Checks the [TEST] lines of one suite. $1 is the suite file, or empty
# for the suite mkxp.json names. $2 is the lines.
check_suite() {
    label="${1:-the suite}"
    DONE_LINE="$(printf '%s\n' "$2" | grep '^\[TEST\] DONE' | head -n 1 || true)"
    if [ -z "$DONE_LINE" ]; then
        echo "run-engine-tests: $label never reported DONE (waited ${WAITED}s)." >&2
        return 1
    fi

    SEEN_GAME="$(printf '%s\n' "$2" | sed -n 's/^\[TEST\] INFO game=//p' | head -n 1)"
    if [ "$SEEN_GAME" != "$GAME_NAME" ]; then
        echo "run-engine-tests: $label ran in game '$SEEN_GAME', not '$GAME_NAME'." >&2
        return 1
    fi

    PASSED="$(field passed "$DONE_LINE")"
    FAILED="$(field failed "$DONE_LINE")"
    PENDING="$(field pending "$DONE_LINE")"

    if [ -z "$PASSED" ] || [ -z "$FAILED" ] || [ -z "$PENDING" ]; then
        echo "run-engine-tests: $label: could not read the totals off: $DONE_LINE" >&2
        return 1
    fi

    if [ "$FAILED" != "0" ]; then
        echo "run-engine-tests: $label failed. $DONE_LINE" >&2
        return 1
    fi

    # A suite that ran nothing is not a suite that passed. This catches
    # a game folder the engine booted but never read the checks out of.
    if [ "$PASSED" = "0" ]; then
        echo "run-engine-tests: $label: no check passed. $DONE_LINE" >&2
        return 1
    fi

    # The suite states up front how many checks it will run. Compare
    # that against what it reported, so a suite that lost checks along
    # the way cannot report a clean run.
    PLANNED="$(printf '%s\n' "$2" | sed -n 's/^\[TEST\] PLAN \([0-9][0-9]*\).*/\1/p' | head -n 1)"
    if [ -z "$PLANNED" ]; then
        echo "run-engine-tests: $label reported no PLAN line." >&2
        return 1
    fi

    RAN=$((PASSED + FAILED + PENDING))
    if [ "$RAN" != "$PLANNED" ]; then
        echo "run-engine-tests: $label planned $PLANNED checks, ran $RAN. $DONE_LINE" >&2
        return 1
    fi

    echo "run-engine-tests: $label: $DONE_LINE (planned $PLANNED)"
}

STATUS=0
if [ -z "$SUITES" ]; then
    check_suite "" "$RESULTS" || STATUS=1
fi
for suite in $SUITES
do
    # The host applies --suite to the copy of the game folder it makes
    # at launch. Nothing before this point proves the engine read that
    # copy, so find each suite by the name the harness printed.
    want="$(suite_name "$suite")"
    block="$(printf '%s\n' "$RESULTS" | awk -v want="$want" '
        /^\[TEST\] SUITE / { inside = ($3 == want) }
        inside')"
    if [ -z "$block" ]; then
        echo "run-engine-tests: asked for $suite, but no run reported suite '$want'." >&2
        STATUS=1
        continue
    fi
    check_suite "$suite" "$block" || STATUS=1
done

if [ "$STATUS" != "0" ]; then
    echo "Last 20 console lines:" >&2
    tail -n 20 "$CONSOLE" >&2
    exit 1
fi
