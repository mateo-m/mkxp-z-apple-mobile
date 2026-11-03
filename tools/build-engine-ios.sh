#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Build the engine for one SDK: libmkxpz-core.a and the three
# mkxp<NN>-merged.o binding objects, from the dependency tree that
# tools/build-deps-ios.sh wrote.
#
# `make mkxp-merged mkxp-core` in deps/ builds the same files, but it
# also checks every dependency against its source tree. After a CI
# cache restore there are no source trees, so make builds every
# dependency again. This script reads only the installed tree.
#
# Usage:
#   tools/build-engine-ios.sh --sdk iphoneos|iphonesimulator|macosx
#                             [--out <libdir>] [--obj <objdir>]
#                             [--arch arm64] [--min-os 26.0]
#
# --out defaults to deps/build-<sdk>-<arch>/lib, the folder that
# tools/package-ios.sh reads.
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"

SDK=""
ARCH=arm64
MIN_OS=26.0
OUT=""
OBJ=""

while [ "$#" -gt 0 ]
do
    case "$1" in
        --sdk) SDK="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --min-os) MIN_OS="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --obj) OBJ="$2"; shift 2 ;;
        *) echo "build-engine-ios: unknown argument $1" >&2; exit 2 ;;
    esac
done

if [ -z "$SDK" ]; then
    echo "build-engine-ios: --sdk is required" >&2
    exit 2
fi

TREE="$ENGINE/deps/build-$SDK-$ARCH"
ANGLE="$ENGINE/deps/ANGLE/$SDK"
OUT="${OUT:-$TREE/lib}"
OBJ="${OBJ:-$TREE/engine-obj}"

if [ ! -d "$TREE/lib" ] || [ ! -d "$ANGLE/include" ]; then
    echo "build-engine-ios: dependency libraries missing." >&2
    echo "Run tools/build-deps-ios.sh $SDK first." >&2
    exit 1
fi

# The header search order differs between the core and the binding.
# Keep each one, because two folders can hold a header of the same
# name.
"$ENGINE/tools/build-core-ios.sh" \
    --sdk "$SDK" --arch "$ARCH" --min-os "$MIN_OS" \
    --obj "$OBJ/core" --out "$OUT" \
    --include "$TREE/include" \
    --include "$TREE/include/AL" \
    --include "$TREE/include/SDL2" \
    --include "$TREE/include/pixman-1" \
    --include "$TREE/include/uchardet" \
    --include "$TREE/include/freetype2" \
    --include "$ANGLE/include"

build_binding() {
    # $1 = 18|19|31, $2 = header dir, $3 = static archive, $4 = ext archive
    "$ENGINE/tools/build-binding-ios.sh" --ruby "$1" \
        --sdk "$SDK" --arch "$ARCH" --min-os "$MIN_OS" \
        --obj "$OBJ/binding$1" --out "$OUT" --scratch "$OBJ" \
        --ruby-include "$TREE/include/$2" \
        --static-lib "$TREE/lib/$3" --ext-lib "$TREE/lib/$4" \
        --include "$TREE/include/SDL2" \
        --include "$TREE/include/pixman-1" \
        --include "$TREE/include/uchardet" \
        --include "$TREE/include/freetype2" \
        --include "$TREE/include" \
        --include "$ANGLE/include"
}
build_binding 31 ruby31 libruby.3.1-static.a libruby.3.1-ext.a
build_binding 19 ruby19 libruby19-static.a libruby19-ext.a
build_binding 18 ruby18 libruby18-static.a libruby18-ext.a

"$ENGINE/tools/binding-fingerprint.sh" > "$OUT/.mkxp-binding-fingerprint"
echo "[mkxp-engine] Done: $OUT"
