#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Mateo M. Additional terms apply: see ADDITIONAL-TERMS.md.

# Build the engine for one SDK: libmkxpz-core.a and the three
# mkxp<NN>-merged.o binding objects, from the dependency tree that
# tools/build-deps-ios.sh wrote.
#
# The make rules in deps/common.make call this script for each part.
# After a CI cache restore there are no source trees, and make would
# build every dependency again, so CI calls this script directly.
#
# Usage:
#   tools/build-engine-ios.sh --sdk iphoneos|iphonesimulator|macosx
#                             [--part all|core|31|19|18]
#                             [--out <libdir>] [--obj <objdir>]
#
# --out defaults to deps/build-<sdk>-<arch>/lib, the folder that
# tools/package-ios.sh reads. deps/<sdk>.make sets the architecture
# and the minimum OS.
set -eu

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"

SDK=""
PART=all
OUT=""
OBJ=""

while [ "$#" -gt 0 ]
do
    case "$1" in
        --sdk) SDK="$2"; shift 2 ;;
        --part) PART="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --obj) OBJ="$2"; shift 2 ;;
        *) echo "build-engine-ios: unknown argument $1" >&2; exit 2 ;;
    esac
done

case "$PART" in
    all|core|31|19|18) ;;
    *) echo "build-engine-ios: --part must be all, core, 31, 19 or 18" >&2; exit 2 ;;
esac

MAKEFILE="$ENGINE/deps/$SDK.make"
if [ -z "$SDK" ] || [ ! -f "$MAKEFILE" ]; then
    echo "build-engine-ios: --sdk must name a deps/<sdk>.make file" >&2
    exit 2
fi
ARCH=$(sed -n 's/^ARCH := //p' "$MAKEFILE")
MIN_OS=$(sed -n 's/^MINIMUM_REQUIRED := //p' "$MAKEFILE")

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
build_core() {
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
}

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

case "$PART" in
    core) build_core ;;
    31) build_binding 31 ruby31 libruby.3.1-static.a libruby.3.1-ext.a ;;
    19) build_binding 19 ruby19 libruby19-static.a libruby19-ext.a ;;
    18) build_binding 18 ruby18 libruby18-static.a libruby18-ext.a ;;
    all)
        build_core
        build_binding 31 ruby31 libruby.3.1-static.a libruby.3.1-ext.a
        build_binding 19 ruby19 libruby19-static.a libruby19-ext.a
        build_binding 18 ruby18 libruby18-static.a libruby18-ext.a
        # A single part leaves the stamp alone, because the stamp
        # says that all three binding objects match the sources.
        "$ENGINE/tools/binding-fingerprint.sh" > "$OUT/.mkxp-binding-fingerprint"
        ;;
esac
echo "[mkxp-engine] Done: $PART in $OUT"
