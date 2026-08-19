#!/bin/sh
# Build the test host, run the in-engine suite on a simulator, and
# report what it found.
#
# The suite needs a running engine: a GPU, a window, and a Ruby VM.
# That is what makes it different from tests/cpp, which needs only a
# compiler. It still needs no person and no launcher.
#
# Usage:
#   tools/run-engine-tests.sh [--device <name or udid>] [--game <dir>]
#                             [--timeout <seconds>] [--keep] [--no-build]
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
KEEP=0
BUILD=1
BUNDLE_ID=sh.mateo.mkxpz.enginetests

while [ "$#" -gt 0 ]
do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --game) GAME="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --no-build) BUILD=0; shift ;;
        *) echo "run-engine-tests: unknown argument $1" >&2; exit 2 ;;
    esac
done

if ! xcrun simctl help >/dev/null 2>&1; then
    echo "run-engine-tests: simctl not available. Install Xcode." >&2
    exit 2
fi

APP="$ENGINE/build/iphonesimulator-arm64/EngineTests.app"

if [ "$BUILD" = "1" ]; then
    "$ENGINE/tools/build-test-host-ios.sh" --game "$GAME" >/dev/null
fi

if [ ! -d "$APP" ]; then
    echo "run-engine-tests: $APP missing. Drop --no-build." >&2
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

NAME="$(xcrun simctl list devices | grep "$DEVICE" | sed 's/ *(.*//' | head -n 1)"
echo "run-engine-tests: using $NAME ($DEVICE)"

xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true

# --- Install ----------------------------------------------------------
xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
if ! xcrun simctl install "$DEVICE" "$APP"; then
    echo "run-engine-tests: install failed" >&2
    exit 1
fi

# --- Run --------------------------------------------------------------
CONSOLE="$(mktemp "${TMPDIR:-/tmp}/mkxpz-engine-tests.XXXXXX")"
if [ "$KEEP" = "0" ]; then
    trap 'rm -f "$CONSOLE"' EXIT INT TERM
fi

echo "run-engine-tests: launching..."
xcrun simctl launch --console-pty "$DEVICE" "$BUNDLE_ID" > "$CONSOLE" 2>&1 &
LAUNCH_PID=$!

# The suite ends with `exit`, which ends the process, but a crash or a
# hang would leave the launch running forever. Poll for the DONE line
# and give up after the timeout.
WAITED=0
while [ "$WAITED" -lt "$TIMEOUT" ]
do
    if grep -aq '^\[TEST\] DONE' "$CONSOLE" 2>/dev/null; then
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

grep -a '^\[TEST\]' "$CONSOLE" || true

DONE_LINE="$(grep -a '^\[TEST\] DONE' "$CONSOLE" | tail -n 1 || true)"
if [ -z "$DONE_LINE" ]; then
    echo "run-engine-tests: the suite never reported DONE (waited ${WAITED}s)." >&2
    echo "Last 20 console lines:" >&2
    tail -n 20 "$CONSOLE" >&2
    exit 1
fi

field() {
    printf '%s\n' "$2" | sed -n "s/.*$1=\([0-9][0-9]*\).*/\1/p"
}

PASSED="$(field passed "$DONE_LINE")"
FAILED="$(field failed "$DONE_LINE")"
PENDING="$(field pending "$DONE_LINE")"

if [ -z "$PASSED" ] || [ -z "$FAILED" ] || [ -z "$PENDING" ]; then
    echo "run-engine-tests: could not read the totals off: $DONE_LINE" >&2
    exit 1
fi

if [ "$FAILED" != "0" ]; then
    echo "run-engine-tests: $DONE_LINE" >&2
    exit 1
fi

# A suite that ran nothing is not a suite that passed. This catches a
# game folder the engine booted but never read the checks out of.
if [ "$PASSED" = "0" ]; then
    echo "run-engine-tests: no check passed. $DONE_LINE" >&2
    exit 1
fi

# The suite states up front how many checks it will run. Compare that
# against what it reported, so a suite that lost checks along the way
# cannot report a clean run.
PLAN_LINE="$(grep -a '^\[TEST\] PLAN' "$CONSOLE" | tail -n 1 || true)"
PLANNED="$(printf '%s\n' "$PLAN_LINE" | sed -n 's/^\[TEST\] PLAN \([0-9][0-9]*\).*/\1/p')"
if [ -z "$PLANNED" ]; then
    echo "run-engine-tests: the suite reported no PLAN line." >&2
    exit 1
fi

RAN=$((PASSED + FAILED + PENDING))
if [ "$RAN" != "$PLANNED" ]; then
    echo "run-engine-tests: planned $PLANNED checks, ran $RAN. $DONE_LINE" >&2
    exit 1
fi

echo "run-engine-tests: $DONE_LINE (planned $PLANNED)"
