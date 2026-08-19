#!/bin/sh
# Build and run the host-side C++ tests in tests/cpp.
#
# These cover engine code that needs no window, no GPU, and no Ruby.
# They compile against the sources under src/ directly, so they need
# no prebuilt library, no simulator, and no launcher. A clone of this
# repository plus a C++ compiler is the whole requirement.
#
# Usage:
#   tools/run-cpp-tests.sh [--keep] [--verbose]
#
#   --keep      leave the built binary in place for a debugger
#   --verbose   show the engine's own stderr output, which the run
#               otherwise hides
#
# Environment:
#   CXX         compiler to use (default c++)
#
# Exit status: 0 all checks passed, 1 a check failed, 2 build error.
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="$ENGINE/tests/cpp"
BUILD="$ENGINE/tests/cpp/build"
BINARY="$BUILD/cpp-tests"
CXX="${CXX:-c++}"
KEEP=0
VERBOSE=0

while [ $# -gt 0 ]
do
    case "$1" in
        --keep)
            KEEP=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            sed -n '2,21p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown option $1" >&2
            exit 2
            ;;
    esac
done

# Engine sources under test. Add a file here when a test file starts
# covering it. Anything that pulls in SDL, PhysFS, or the Ruby binding
# does not belong in this list: those need the full engine build.
ENGINE_SOURCES="
$ENGINE/src/patcher.cpp
$ENGINE/src/util/iniconfig.cpp
"

mkdir -p "$BUILD"

# MKXPZ_MOBILE=0 selects the inline no-op host bridge in
# app_bridge.h, so the tests need no launcher and no stub file.
# The source list is deliberately split into words.
# shellcheck disable=SC2086
$CXX -std=c++17 -g -O0 \
    -DMKXPZ_MOBILE=0 \
    -I"$ENGINE/src" \
    -I"$TESTS" \
    -o "$BINARY" \
    "$TESTS"/*.cpp $ENGINE_SOURCES ||
    {
        echo "error: the tests did not build." >&2
        exit 2
    }

# Spell out the template. GNU mktemp rejects a -t prefix that holds
# no X, so the BSD short form fails on Linux.
STDERR="$(mktemp "${TMPDIR:-/tmp}/mkxp-cpp-tests.XXXXXX")"
STATUS=0
"$BINARY" 2> "$STDERR" || STATUS=$?

if [ "$VERBOSE" = "1" ] || [ "$STATUS" != "0" ]
then
    if [ -s "$STDERR" ]
    then
        echo
        echo "--- engine output ---"
        cat "$STDERR"
    fi
fi
rm -f "$STDERR"

if [ "$KEEP" = "0" ]
then
    rm -rf "$BUILD"
fi

exit "$STATUS"
