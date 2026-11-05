#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Build and run the MIDI tests in tests/midi on this Mac.
#
# The tests link the static FluidSynth of a macosx dependency tree and
# load the test SoundFonts that ship in the FluidSynth sources.
#
# Usage:
#   tools/run-midi-tests.sh [--deps DIR]
#
#   --deps DIR  the dependency tree (default deps/build-macosx-arm64)
#
# Exit status: 0 all checks passed, 1 a check failed, 2 build error.
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ENGINE/deps/build-macosx-arm64"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/mkxp-midi-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

while [ $# -gt 0 ]
do
    case "$1" in
        --deps)
            DEPS="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,15p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown option $1" >&2
            exit 2
            ;;
    esac
done

SOUNDFONTS="$ENGINE/deps/sources/fluidsynth/sf2"
if [ ! -f "$SOUNDFONTS/VintageDreamsWaves-v2.dls" ]
then
    git -C "$ENGINE" -c url.https://github.com/.insteadOf=git@github.com: \
        submodule update --init --depth 1 deps/sources/fluidsynth
fi

c++ -std=c++17 -g -O0 \
    -DMKXPZ_MOBILE=0 -DTEST_SUITE='"midi"' \
    -I"$ENGINE/src" -I"$ENGINE/src/util" -I"$ENGINE/src/audio" \
    -I"$ENGINE/tests/cpp" \
    -I"$DEPS/include" -I"$DEPS/include/SDL2" \
    -o "$BUILD/midi-tests" \
    "$ENGINE/tests/cpp/harness.cpp" \
    "$ENGINE"/tests/midi/*.cpp \
    "$DEPS/lib/libfluidsynth.a" ||
    {
        echo "error: the tests did not build." >&2
        exit 2
    }

MIDI_TEST_SOUNDFONTS="$SOUNDFONTS" "$BUILD/midi-tests"
